# Kernel Linker (KLD)

This document covers the kernel dynamic linker framework (KLD) that supports
loading and unloading kernel modules at runtime.

## Overview

The Kernel Linker (KLD) system provides dynamic loading of kernel modules. It
handles ELF object files, symbol resolution, relocation, and manages module
dependencies. The system supports both:

- **Preloaded modules** - Loaded by the boot loader before the kernel starts
- **Runtime loading** - Loaded via the `kldload(2)` system call

Key features:
- ELF shared object and relocatable object file support
- Automatic dependency resolution and loading
- Symbol export/import between modules and kernel
- SYSINIT/SYSUNINIT execution within modules
- Reference counting for safe unloading

## Key Source Files

| File | Purpose |
|------|---------|
| `sys/kern/kern_linker.c` | Core linker framework and syscalls |
| `sys/kern/kern_module.c` | Module registration and lifecycle |
| `sys/kern/link_elf.c` | ELF shared object (ET_DYN) loader |
| `sys/kern/link_elf_obj.c` | ELF relocatable object (ET_REL) loader |
| `sys/sys/linker.h` | Linker structures and function prototypes |
| `sys/sys/module.h` | Module metadata and macros |

## Architecture

### Linker Classes

The KLD system uses a class-based architecture to support different object file
formats. Each class implements `struct linker_class_ops` (`sys/sys/linker.h:134`):

```c
struct linker_class_ops {
    int  (*load_file)(const char *filename, linker_file_t *result);
    int  (*preload_file)(const char *filename, linker_file_t *result);
};
```

DragonFly BSD registers two ELF linker classes at boot (`SI_BOOT2_KLD`):

1. **elf32/elf64** (link_elf.c) - For shared objects (ET_DYN type)
2. **elf32/elf64** (link_elf_obj.c) - For relocatable objects (ET_REL type)

Classes are tried in order until one successfully loads the file.

### The linker_file Structure

Every loaded module is represented by a `struct linker_file` (`sys/sys/linker.h:107`):

```c
struct linker_file {
    int              refs;        /* reference count */
    int              userrefs;    /* kldload(2) count */
    int              flags;
#define LINKER_FILE_LINKED  0x1   /* file has been fully linked */
    TAILQ_ENTRY(linker_file) link; /* list of all loaded files */
    char            *filename;    /* file which was loaded */
    char            *pathname;    /* file name with full path */
    int              id;          /* unique id */
    caddr_t          address;     /* load address */
    size_t           size;        /* size of file */
    int              ndeps;       /* number of dependencies */
    linker_file_t   *deps;        /* list of dependencies */
    STAILQ_HEAD(, common_symbol) common; /* list of common symbols */
    TAILQ_HEAD(, module) modules; /* modules in this file */
    void            *priv;        /* implementation data */
    struct linker_file_ops *ops;
};
```

File operations provide symbol lookup and unload callbacks:

```c
struct linker_file_ops {
    int   (*lookup_symbol)(linker_file_t, const char *name, c_linker_sym_t *sym);
    int   (*symbol_values)(linker_file_t, c_linker_sym_t, linker_symval_t *);
    int   (*search_symbol)(linker_file_t, caddr_t value, c_linker_sym_t *, long *);
    int   (*preload_finish)(linker_file_t);
    void  (*unload)(linker_file_t);
    int   (*lookup_set)(linker_file_t, const char *name, void ***, void ***, int *);
};
```

### Global State

The linker maintains several global structures (`kern_linker.c:63`):

```c
linker_file_t linker_current_file;   /* file currently being loaded */
linker_file_t linker_kernel_file;    /* the kernel itself */

static struct lock llf_lock;         /* lock for the file list */
static struct lock kld_lock;         /* general kld lock */
static linker_class_list_t classes;  /* registered file classes */
static linker_file_list_t linker_files; /* all loaded files */
static int next_file_id = 1;
```

## Module Loading

### Loading from Filesystem

The `sys_kldload()` syscall (`kern_linker.c:782`) loads a module:

```c
int sys_kldload(struct sysmsg *sysmsg, const struct kldload_args *uap)
{
    /* Security checks */
    if (securelevel > 0 || kernel_mem_readonly)
        return EPERM;
    if ((error = caps_priv_check_self(SYSCAP_NOKLD)) != 0)
        return error;

    /* Determine if file path or module name */
    if (strchr(file, '/') || strchr(file, '.')) {
        kldname = file;    /* full path or .ko file */
        modname = NULL;
    } else {
        kldname = NULL;
        modname = file;    /* module name - search path */
    }

    lockmgr(&kld_lock, LK_EXCLUSIVE);
    error = linker_load_module(kldname, modname, NULL, NULL, &lf);
    lockmgr(&kld_lock, LK_RELEASE);

    if (!error) {
        lf->userrefs++;
        sysmsg->sysmsg_result = lf->id;
    }
    return error;
}
```

The `linker_load_file()` function (`kern_linker.c:310`) is the core loader:

```c
int linker_load_file(const char *filename, linker_file_t *result)
{
    /* Security check */
    if (securelevel > 0 || kernel_mem_readonly)
        return EPERM;

    /* Check if already loaded */
    lf = linker_find_file_by_name(filename);
    if (lf) {
        lf->refs++;
        *result = lf;
        return 0;
    }

    /* Try each class until one succeeds */
    TAILQ_FOREACH(lc, &classes, link) {
        error = lc->ops->load_file(filename, &lf);
        if (lf) {
            linker_file_register_modules(lf);
            linker_file_register_sysctls(lf);
            linker_file_sysinit(lf);
            lf->flags |= LINKER_FILE_LINKED;
            *result = lf;
            return 0;
        }
    }
    return error;
}
```

### Module Search Path

The linker searches for modules using a configurable path (`kern_linker.c:1406`):

```c
static char linker_path[MAXPATHLEN] = "/boot/kernel;/boot/modules.local";

SYSCTL_STRING(_kern, OID_AUTO, module_path, CTLFLAG_RW, linker_path,
              sizeof(linker_path), "module load search path");
```

The `linker_search_path()` function tries each path component with optional
`.ko` extension until a file is found.

### Preloaded Modules

Modules loaded by the boot loader are processed during kernel initialization
by `linker_preload()` (`kern_linker.c:1208`):

1. Iterate through preload metadata finding modules
2. Call each linker class's `preload_file()` to parse the module
3. Sort modules by dependency order (bubble sort)
4. Call `preload_finish()` to complete relocation
5. Register modules and run SYSINITs

```c
static void linker_preload(void *arg)
{
    /* Find all preloaded modules */
    while ((modptr = preload_search_next_name(modptr)) != NULL) {
        TAILQ_FOREACH(lc, &classes, link) {
            error = lc->ops->preload_file(modname, &lf);
            if (!error) break;
        }
        if (lf)
            TAILQ_INSERT_TAIL(&loaded_files, lf, loaded);
    }

    /* Resolve dependencies and link order */
    /* ... bubble sort by dependencies ... */

    /* Complete loading */
    TAILQ_FOREACH(lf, &depended_files, loaded) {
        lf->ops->preload_finish(lf);
        linker_file_register_modules(lf);
        linker_file_register_sysctls(lf);
        lf->flags |= LINKER_FILE_LINKED;
    }
}

SYSINIT(preload, SI_BOOT2_KLD, SI_ORDER_MIDDLE, linker_preload, 0);
```

## ELF Loading

### Shared Objects (link_elf.c)

For ET_DYN (shared object) files, `link_elf_load_file()` (`link_elf.c:388`):

1. **Read and validate ELF header**
2. **Parse program headers** - Find PT_LOAD segments (text, data) and PT_DYNAMIC
3. **Allocate memory** - `kmalloc()` for the module's address space
4. **Load segments** - Read text/data, zero BSS
5. **Parse dynamic section** - Extract symbol table, hash table, relocations
6. **Perform local relocations** - `link_elf_reloc_local()`
7. **Load dependencies** - `linker_load_dependencies()`
8. **Perform global relocations** - `relocate_file()`
9. **Load debug symbols** (optional)

The ELF file structure (`link_elf.c:89`):

```c
typedef struct elf_file {
    caddr_t          address;     /* Relocation address */
    const Elf_Dyn   *dynamic;     /* Symbol table etc. */
    Elf_Hashelt      nbuckets;    /* DT_HASH info */
    Elf_Hashelt      nchains;
    const Elf_Hashelt *buckets;
    const Elf_Hashelt *chains;
    caddr_t          strtab;      /* DT_STRTAB */
    int              strsz;       /* DT_STRSZ */
    const Elf_Sym   *symtab;      /* DT_SYMTAB */
    Elf_Addr        *got;         /* DT_PLTGOT */
    const Elf_Rela  *rela;        /* DT_RELA */
    int              relasize;    /* DT_RELASZ */
    const Elf_Sym   *ddbsymtab;   /* Symbol table for DDB */
    long             ddbsymcnt;
    caddr_t          ddbstrtab;   /* String table */
    long             ddbstrcnt;
} *elf_file_t;
```

### Relocatable Objects (link_elf_obj.c)

For ET_REL (relocatable object) files used by most kernel modules,
`link_elf_obj_load_file()` (`link_elf_obj.c:390`):

1. **Read and validate ELF header** - Must be ET_REL type
2. **Read section headers** - Parse all sections
3. **Count sections** - PROGBITS, NOBITS, REL, RELA
4. **Allocate symbol/string tables** - Read into memory
5. **Allocate contiguous memory** - For all code/data sections
6. **Load sections** - Read PROGBITS, zero NOBITS
7. **Update symbol values** - Add section base addresses
8. **Perform local relocations** - `link_elf_obj_reloc_local()`
9. **Load dependencies** - `linker_load_dependencies()`
10. **Perform global relocations** - `relocate_file()`

The object file structure (`link_elf_obj.c:104`):

```c
typedef struct elf_file {
    int              preloaded;
    caddr_t          address;     /* Relocation address */
    size_t           bytes;       /* Chunk size in bytes */
    vm_object_t      object;      /* VM object for pages */
    Elf_Shdr        *e_shdr;      /* Section headers */
    Elf_progent     *progtab;     /* PROGBITS/NOBITS sections */
    int              nprogtab;
    Elf_relaent     *relatab;     /* RELA relocations */
    int              nrelatab;
    Elf_relent      *reltab;      /* REL relocations */
    int              nreltab;
    Elf_Sym         *ddbsymtab;   /* Symbol table */
    long             ddbsymcnt;
    caddr_t          ddbstrtab;   /* String table */
    long             ddbstrcnt;
} *elf_file_t;
```

### Symbol Lookup

Symbol lookup uses the ELF hash table for efficiency (`link_elf.c:776`):

```c
static unsigned long elf_hash(const char *name)
{
    /* Standard System V ABI hash function */
    const unsigned char *p = (const unsigned char *)name;
    unsigned long h = 0, g;

    while (*p != '\0') {
        h = (h << 4) + *p++;
        if ((g = h & 0xf0000000) != 0)
            h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

static int link_elf_lookup_symbol(linker_file_t lf, const char *name,
                                  c_linker_sym_t *sym)
{
    unsigned long hash = elf_hash(name);
    unsigned long symnum = ef->buckets[hash % ef->nbuckets];

    while (symnum != STN_UNDEF) {
        symp = ef->symtab + symnum;
        strp = ef->strtab + symp->st_name;
        if (strcmp(name, strp) == 0) {
            if (symp->st_shndx != SHN_UNDEF) {
                *sym = (c_linker_sym_t)symp;
                return 0;
            }
        }
        symnum = ef->chains[symnum];
    }
    return ENOENT;
}
```

For undefined symbols, `linker_file_lookup_symbol()` (`kern_linker.c:605`)
searches:
1. The file's own symbol table
2. Dependencies (if `deps` flag set)
3. All loaded files (global search)
4. Common symbol table (allocates storage if needed)

### Relocation

Relocation applies fixups to resolve symbol references. The `relocate_file()`
function processes both REL and RELA relocation entries:

```c
static int relocate_file(linker_file_t lf)
{
    /* Process REL entries (addend in instruction) */
    for (rel = ef->rel; rel < rellim; rel++) {
        if (elf_reloc(lf, ef->address, rel, ELF_RELOC_REL, elf_lookup)) {
            kprintf("link_elf: symbol %s undefined\n", symname);
            return ENOENT;
        }
    }

    /* Process RELA entries (explicit addend) */
    for (rela = ef->rela; rela < relalim; rela++) {
        if (elf_reloc(lf, ef->address, rela, ELF_RELOC_RELA, elf_lookup)) {
            kprintf("link_elf: symbol %s undefined\n", symname);
            return ENOENT;
        }
    }
    return 0;
}
```

Architecture-specific `elf_reloc()` and `elf_reloc_local()` functions handle
the actual relocation types (e.g., R_X86_64_64, R_X86_64_PC32, etc.).

## Module System

### Module Registration

Modules within a KLD file are registered via `module_register()` (`kern_module.c:120`):

```c
int module_register(const moduledata_t *data, linker_file_t container)
{
    newmod = module_lookupbyname(data->name);
    if (newmod != NULL)
        return EEXIST;  /* already registered */

    newmod = kmalloc(sizeof(struct module) + namelen, M_MODULE, M_WAITOK);
    newmod->refs = 1;
    newmod->id = nextid++;
    newmod->name = (char *)(newmod + 1);
    strcpy(newmod->name, data->name);
    newmod->handler = data->evhand ? data->evhand : modevent_nop;
    newmod->arg = data->priv;

    TAILQ_INSERT_TAIL(&modules, newmod, link);
    if (container)
        TAILQ_INSERT_TAIL(&container->modules, newmod, flink);
    newmod->file = container;
    return 0;
}
```

The `struct module` (`kern_module.c:43`):

```c
struct module {
    TAILQ_ENTRY(module) link;    /* chain all modules */
    TAILQ_ENTRY(module) flink;   /* modules in this file */
    struct linker_file *file;    /* containing file */
    int              refs;       /* reference count */
    int              id;         /* unique id number */
    char            *name;       /* module name */
    modeventhand_t   handler;    /* event handler */
    void            *arg;        /* argument for handler */
    modspecific_t    data;       /* module specific data */
};
```

### Module Events

Modules receive lifecycle events via their handler:

```c
typedef enum modeventtype {
    MOD_LOAD,      /* Module is being loaded */
    MOD_UNLOAD,    /* Module is being unloaded */
    MOD_SHUTDOWN   /* System is shutting down */
} modeventtype_t;
```

### Module Metadata

Modules declare metadata using macros from `sys/sys/module.h`:

```c
/* Declare a module */
DECLARE_MODULE(name, data, sub, order);

/* Declare a dependency on another module */
MODULE_DEPEND(module, mdepend, vmin, vpref, vmax);

/* Declare module version */
MODULE_VERSION(module, version);
```

These expand to `struct mod_metadata` entries in the `modmetadata_set` linker set:

```c
struct mod_metadata {
    int         md_version;   /* structure version */
    int         md_type;      /* MDT_DEPEND, MDT_MODULE, or MDT_VERSION */
    void       *md_data;      /* type-specific data */
    const char *md_cval;      /* module/dependency name */
};
```

### Dependency Resolution

The linker resolves dependencies during loading (`kern_linker.c:1582`):

```c
int linker_load_dependencies(linker_file_t lf)
{
    /* All files depend on kernel */
    if (linker_kernel_file) {
        linker_kernel_file->refs++;
        linker_file_add_dependancy(lf, linker_kernel_file);
    }

    /* Process MDT_DEPEND entries */
    linker_file_lookup_set(lf, MDT_SETNAME, &start, &stop, NULL);
    for (mdp = start; mdp < stop; mdp++) {
        if ((*mdp)->md_type != MDT_DEPEND)
            continue;
        modname = (*mdp)->md_cval;
        verinfo = (*mdp)->md_data;

        /* Skip self-references */
        /* Check if already loaded */
        mod = modlist_lookup2(modname, verinfo);
        if (mod) {
            lfdep = mod->container;
            lfdep->refs++;
            linker_file_add_dependancy(lf, lfdep);
            continue;
        }
        /* Load the dependency */
        error = linker_load_module(NULL, modname, lf, verinfo, NULL);
    }
    return error;
}
```

## Module Unloading

### Unload Flow

The `sys_kldunload()` syscall (`kern_linker.c:833`) unloads a module:

```c
int sys_kldunload(struct sysmsg *sysmsg, const struct kldunload_args *uap)
{
    if (securelevel > 0 || kernel_mem_readonly)
        return EPERM;

    lockmgr(&kld_lock, LK_EXCLUSIVE);
    lf = linker_find_file_by_id(uap->fileid);
    if (lf) {
        if (lf->userrefs == 0) {
            /* kernel-loaded, cannot unload */
            error = EBUSY;
        } else {
            lf->userrefs--;
            error = linker_file_unload(lf);
            if (error)
                lf->userrefs++;  /* restore on failure */
        }
    }
    lockmgr(&kld_lock, LK_RELEASE);
    return error;
}
```

The `linker_file_unload()` function (`kern_linker.c:477`):

1. **Check reference count** - If refs > 1, just decrement
2. **Notify modules** - Send MOD_UNLOAD event (may veto)
3. **Run SYSUNINITs** - In reverse order
4. **Unregister sysctls**
5. **Unload dependencies** - Recursively
6. **Free resources** - Call class unload, free memory

```c
int linker_file_unload(linker_file_t file)
{
    if (securelevel > 0 || kernel_mem_readonly)
        return EPERM;

    /* Just drop reference if not last */
    if (file->refs > 1) {
        file->refs--;
        return 0;
    }

    /* Notify modules - they can veto */
    for (mod = TAILQ_FIRST(&file->modules); mod; mod = next) {
        next = module_getfnext(mod);
        if ((error = module_unload(mod)) != 0)
            return error;  /* vetoed */
        module_release(mod);
    }

    /* Run SYSUNINITs */
    if (file->flags & LINKER_FILE_LINKED) {
        linker_file_sysuninit(file);
        linker_file_unregister_sysctls(file);
    }

    /* Unload dependencies */
    for (i = 0; i < file->ndeps; i++)
        linker_file_unload(file->deps[i]);

    /* Class-specific cleanup */
    file->ops->unload(file);
    kfree(file, M_LINKER);
    return 0;
}
```

### SYSINIT in Modules

Modules can include SYSINIT entries that run when the module loads:

```c
static void linker_file_sysinit(linker_file_t lf)
{
    /* Find sysinit_set in the module */
    if (linker_file_lookup_set(lf, "sysinit_set", &start, &stop, NULL) != 0)
        return;

    /* Sort by subsystem and order (bubble sort) */
    for (sipp = start; sipp < stop; sipp++) {
        for (xipp = sipp + 1; xipp < stop; xipp++) {
            if ((*sipp)->subsystem > (*xipp)->subsystem ||
                ((*sipp)->subsystem == (*xipp)->subsystem &&
                 (*sipp)->order > (*xipp)->order)) {
                save = *sipp; *sipp = *xipp; *xipp = save;
            }
        }
    }

    /* Execute in order */
    for (sipp = start; sipp < stop; sipp++) {
        if ((*sipp)->subsystem != SI_SPECIAL_DUMMY)
            (*((*sipp)->func))((*sipp)->udata);
    }
}
```

SYSUNINITs run in reverse order during unload.

## KLD Syscalls

| Syscall | Description |
|---------|-------------|
| `kldload(2)` | Load a kernel module |
| `kldunload(2)` | Unload a kernel module |
| `kldfind(2)` | Find a loaded module by name |
| `kldnext(2)` | Iterate over loaded modules |
| `kldstat(2)` | Get module statistics |
| `kldfirstmod(2)` | Get first module in a file |
| `kldsym(2)` | Look up a symbol |

Module information syscalls:

| Syscall | Description |
|---------|-------------|
| `modnext(2)` | Iterate over registered modules |
| `modfnext(2)` | Next module in same file |
| `modstat(2)` | Get module statistics |
| `modfind(2)` | Find module by name |

## DDB Integration

The linker provides helpers for the kernel debugger (DDB) to look up symbols
across all loaded modules (`kern_linker.c:718`):

```c
int linker_ddb_lookup(const char *symstr, c_linker_sym_t *sym)
{
    TAILQ_FOREACH(lf, &linker_files, link) {
        if (lf->ops->lookup_symbol(lf, symstr, sym) == 0)
            return 0;
    }
    return ENOENT;
}

int linker_ddb_search_symbol(caddr_t value, c_linker_sym_t *sym, long *diffp)
{
    /* Find closest symbol to address across all files */
    TAILQ_FOREACH(lf, &linker_files, link) {
        if (lf->ops->search_symbol(lf, value, &es, &diff) == 0) {
            if (es != NULL && diff < bestdiff) {
                best = es;
                bestdiff = diff;
            }
        }
    }
    /* ... */
}
```

## Security

Module loading is restricted by:

1. **Securelevel** - Loading blocked if `securelevel > 0`
2. **kernel_mem_readonly** - Loading blocked if set
3. **Capabilities** - Requires `SYSCAP_NOKLD` capability

## See Also

- [initialization.md](initialization.md) - Kernel boot and SYSINIT
- [syscalls.md](syscalls.md) - Syscall registration for modules
- [devices.md](devices.md) - Device driver modules
