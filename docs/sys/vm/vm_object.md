# VM Objects

VM objects are the fundamental abstraction for managing virtual memory contents in DragonFly BSD. Each object represents a contiguous range of virtual memory that can be backed by files, swap space, devices, or anonymous memory.

**Source file:** `sys/vm/vm_object.c` (~2,034 lines)

## Where Objects Fit in the VM Hierarchy

```
USER PROCESS                     VM SUBSYSTEM
─────────────                    ────────────
                                     
ptr = mmap(file)                 vm_map_entry
     │                                │
     │                           vm_map_backing
     │                                │
     └──────────────────────────► vm_object ◄───── vnode_pager
                                      │
                               ┌──────┼──────┐
                               │      │      │
                            vm_page vm_page vm_page
                              (RB tree by page index)
```

**Key insight:** Objects are the *container* for pages. They don't manage address spaces (that's `vm_map`) or physical allocation (that's `vm_page`). They manage:

- Which pages belong together logically
- How to populate missing pages (via pager)
- Sharing between processes (file-backed)

## Common Scenarios

| Scenario | Object Type | What Happens |
|----------|-------------|--------------|
| `malloc(large)` | OBJT_DEFAULT→OBJT_SWAP | Anonymous object created, pages added on fault, swapped under pressure |
| `mmap(file)` | OBJT_VNODE | Object tied to vnode, pages loaded from file on fault |
| `fork()` | Parent's objects | Child gets new vm_map_backing pointing to same objects (COW) |
| GPU memory | OBJT_MGTDEVICE | Device manages pages, object tracks mappings |
| `shm_open()` | OBJT_SWAP | Swap-backed object shared between processes |

---

## Overview

A VM object maintains:

- A red-black tree of resident physical pages (`rb_memq`)
- Reference count for lifetime management
- Type-specific backing store (file, swap, device)
- A list of `vm_map_backing` structures that reference this object

Objects are the bridge between address space mappings (`vm_map_entry`) and physical pages (`vm_page`). A single page exists within exactly one object at any given time.

## Object Types

```c
enum obj_type {
    OBJT_DEFAULT,    /* Anonymous memory, initially no backing */
    OBJT_SWAP,       /* Backed by swap blocks */
    OBJT_VNODE,      /* Backed by file (vnode) */
    OBJT_DEVICE,     /* Device-backed pages */
    OBJT_MGTDEVICE,  /* Managed device pager */
    OBJT_PHYS,       /* Physical pages (no paging) */
    OBJT_DEAD,       /* Being destroyed */
    OBJT_MARKER,     /* List iteration marker */
};
```

### Type Characteristics

| Type | Backing Store | Pages in rb_memq | Swappable |
|------|---------------|------------------|-----------|
| OBJT_DEFAULT | None initially | Yes | Converts to SWAP |
| OBJT_SWAP | Swap blocks | Yes | Yes |
| OBJT_VNODE | File | Yes | Via file I/O |
| OBJT_DEVICE | Device memory | No (typically) | No |
| OBJT_MGTDEVICE | Managed device | Via backing_list | No |

## Data Structures

### struct vm_object

```c
struct vm_object {
    struct lwkt_token token;           /* Soft-lock for object */
    struct lock backing_lk;            /* Lock for backing_list only */
    struct vm_page_rb_tree rb_memq;    /* Resident pages (RB tree) */
    TAILQ_HEAD(,vm_map_backing) backing_list;  /* Who references us */
    
    vm_pindex_t size;                  /* Size in pages */
    int ref_count;                     /* Reference count */
    int hold_count;                    /* Destruction prevention */
    u_int paging_in_progress;          /* Active I/O operations */
    
    objtype_t type;                    /* OBJT_* type */
    u_short flags;                     /* OBJ_* flags */
    vm_memattr_t memattr;              /* Memory attributes (PAT) */
    u_short pg_color;                  /* Base page color */
    
    void *handle;                      /* Type-specific (vnode, dev) */
    long resident_page_count;          /* Cached page count */
    int generation;                    /* Modification counter */
    
    /* Swap support */
    struct swblock_rb_tree swblock_root;
    long swblock_count;
};
```

### Object Flags

| Flag | Description |
|------|-------------|
| `OBJ_ACTIVE` | Object is active |
| `OBJ_DEAD` | Being destroyed |
| `OBJ_NOSPLIT` | Don't split this object |
| `OBJ_ONEMAPPING` | Each page maps to at most one vm_map_entry |
| `OBJ_WRITEABLE` | Has been made writeable |
| `OBJ_MIGHTBEDIRTY` | May have dirty pages |
| `OBJ_CLEANING` | Page cleaning in progress |
| `OBJ_DEADWNT` | Waiter for object death |

### Global Hash Table

Objects are tracked in a 256-bucket hash table for global enumeration:

```c
struct vm_object_hash vm_object_hash[VMOBJ_HSIZE];  /* VMOBJ_HSIZE = 256 */
```

Each bucket contains a TAILQ list protected by an LWKT token. The hash function uses two large primes for distribution.

## Locking Model

DragonFly uses LWKT tokens (soft-locks) for VM objects, allowing blocking while held:

| Function | Description |
|----------|-------------|
| `vm_object_hold(obj)` | Acquire hold + exclusive token |
| `vm_object_hold_shared(obj)` | Acquire hold + shared token |
| `vm_object_hold_try(obj)` | Non-blocking hold attempt |
| `vm_object_drop(obj)` | Release hold + token |

### Hold Count vs Reference Count

- **ref_count**: Logical references (from mappings, etc.)
- **hold_count**: Prevents object from being freed while working with it

The hold/drop pattern is critical:

```c
/* Must increment hold_count BEFORE blocking on token */
refcount_acquire(&obj->hold_count);  /* Makes object stable */
vm_object_lock(obj);                 /* May block */
/* ... work with object ... */
vm_object_unlock(obj);
if (refcount_release(&obj->hold_count)) {
    if (obj->ref_count == 0 && (obj->flags & OBJ_DEAD))
        kfree_obj(obj, M_VM_OBJECT);  /* Final free */
}
```

## Object Lifecycle

### Allocation

```c
/* Returns unheld object */
vm_object_t vm_object_allocate(objtype_t type, vm_pindex_t size);

/* Returns held object for atomic initialization */
vm_object_t vm_object_allocate_hold(objtype_t type, vm_pindex_t size);
```

Initialization (`_vm_object_allocate()`) performs:

1. Initialize page RB tree and token
2. Initialize `backing_list` and `backing_lk`
3. Set type, size, ref_count=1
4. For DEFAULT/SWAP: set `OBJ_ONEMAPPING`
5. Assign random page color via `vm_quickcolor()`
6. Initialize swap block tree
7. Insert into global hash table

### Reference Counting

**Adding references:**

```c
/* Must hold object token */
void vm_object_reference_locked(vm_object_t object);

/* Safe without token when object is deterministically referenced */
void vm_object_reference_quick(vm_object_t object);
```

For `OBJT_VNODE` objects, these also call `vref()` on the vnode.

**Releasing references:**

```c
void vm_object_deallocate(vm_object_t object);
```

The deallocation path optimizes for the common case:

- **Fast path** (ref_count > 3): Atomic decrement without locking
- **Slow path** (ref_count <= 3): Hold object, handle termination

This avoids exclusive lock contention on highly-shared binaries during exec/exit.

### Termination

When ref_count reaches zero, `vm_object_terminate()` is called:

1. Set `OBJ_DEAD` flag
2. Wait for `paging_in_progress` to reach 0
3. For `OBJT_VNODE`:
   - `vinvalbuf()` - flush buffers
   - `vm_object_page_clean()` - write dirty pages
   - `vinvalbuf()` again (TMPFS special case)
4. Free all resident pages via callback
5. `vm_pager_deallocate()` - notify pager
6. Remove from hash table
7. Object freed when hold_count reaches 0

## Page Management

### Page Cleaning

`vm_object_page_clean()` writes dirty pages to backing store:

```c
void vm_object_page_clean(vm_object_t object, 
                          vm_pindex_t start, 
                          vm_pindex_t end,
                          int flags);
```

**Flags:**

| Flag | Description |
|------|-------------|
| `OBJPC_SYNC` | Synchronous I/O |
| `OBJPC_INVAL` | Invalidate after cleaning |
| `OBJPC_NOSYNC` | Skip PG_NOSYNC pages |
| `OBJPC_CLUSTER_OK` | Allow I/O clustering |

**Two-pass algorithm:**

1. **Pass 1**: Mark all pages read-only (`vm_page_protect(VM_PROT_READ)`)
   - Sets `PG_CLEANCHK` flag on each page
   - If entire object cleaned: clears `OBJ_WRITEABLE|OBJ_MIGHTBEDIRTY`

2. **Pass 2**: Write dirty pages
   - Skips pages without `PG_CLEANCHK` (inserted after pass 1)
   - Clusters adjacent dirty pages for efficient I/O
   - Repeats if object's generation changes

### Page Removal

```c
void vm_object_page_remove(vm_object_t object,
                           vm_pindex_t start,
                           vm_pindex_t end,
                           boolean_t clean_only);
```

This function:

1. Scans `backing_list` to remove pmap mappings (important for MGTDEVICE)
2. Scans `rb_memq` to free pages
3. Frees related swap blocks

The `clean_only` flag preserves dirty pages.

### madvise Support

```c
void vm_object_madvise(vm_object_t object,
                       vm_pindex_t pindex,
                       vm_pindex_t count,
                       int advise);
```

| Advise | Action |
|--------|--------|
| `MADV_WILLNEED` | Activate pages (move to active queue) |
| `MADV_DONTNEED` | Deactivate pages (candidate for reclaim) |
| `MADV_FREE` | Mark clean + deactivate + free swap |

`MADV_FREE` is restricted to `OBJT_DEFAULT`/`OBJT_SWAP` objects with `OBJ_ONEMAPPING`.

## Object Coalescing

```c
boolean_t vm_object_coalesce(vm_object_t prev_object,
                             vm_pindex_t prev_pindex,
                             vm_size_t prev_size,
                             vm_size_t next_size);
```

Extends an object into adjacent virtual memory:

- Only for `OBJT_DEFAULT`/`OBJT_SWAP`
- Requires single reference (or extending into new space)
- Removes any existing pages in the new region
- Updates `object->size`

## Vnode Object Handling

`OBJT_VNODE` objects have special handling:

- **Reference counting**: `vref()`/`vrele()` called alongside object refs
- **VTEXT flag**: Cleared on last reference (executable text)
- **Dirty tracking**: `VOBJDIRTY` flag on vnode for syncer
- **Page cleaning**: Double `vinvalbuf()` for TMPFS compatibility

The `vm_object_vndeallocate()` function handles the complex 1->0 transition:

```c
/* Atomically handle ref_count with retry loop */
if (count == 1) {
    vm_object_upgrade(object);      /* Need exclusive for VTEXT */
    if (atomic_fcmpset_int(&object->ref_count, &count, 0)) {
        vclrflags(vp, VTEXT);
        break;
    }
}
```

## Dirty Flag Management

```c
void vm_object_set_writeable_dirty(vm_object_t object);
```

Called from the fault path when a page becomes writeable:

1. Sets `OBJ_WRITEABLE | OBJ_MIGHTBEDIRTY` on object
2. For `OBJT_VNODE`: sets `VOBJDIRTY` on vnode
   - Uses `vsetobjdirty()` for `MNTK_THR_SYNC` mounts
   - Uses `vsetflags()` for traditional mounts

The flags check before atomic operation avoids contention in the fault path.

## DragonFly-Specific Features

### LWKT Token Locking

Unlike traditional BSD mutexes, LWKT tokens allow:

- Blocking while held
- Other threads to "squeeze in" work
- Shared/exclusive modes
- Token swapping for lock ordering

### backing_list

Each object maintains a list of `vm_map_backing` structures:

```c
TAILQ_HEAD(, vm_map_backing) backing_list;
struct lock backing_lk;  /* Separate lock for this list */
```

This enables:

- Efficient pmap removal during page removal
- Support for `OBJT_MGTDEVICE` (pages not in rb_memq)
- Tracking all mappings of an object

### Page Coloring

`vm_quickcolor()` provides semi-random initial page colors:

```c
int vm_quickcolor(void) {
    globaldata_t gd = mycpu;
    int pg_color = (int)(intptr_t)gd->gd_curthread >> 10;
    pg_color += gd->gd_quick_color;
    gd->gd_quick_color += PQ_PRIME2;
    return pg_color;
}
```

This spreads page allocations across queues for SMP scalability.

## Debugging

DDB commands for object inspection:

| Command | Description |
|---------|-------------|
| `show vmochk` | Verify internal objects are mapped |
| `show object <addr>` | Print object details and pages |
| `show vmopag` | Print page runs for all objects |

## See Also

- [VM Subsystem Overview](index.md) - Architecture overview
- [Physical Page Management](vm_page.md) - Page allocation and queues
