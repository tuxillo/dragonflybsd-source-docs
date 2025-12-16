# Kernel Utilities and Miscellaneous Subsystems

This document covers miscellaneous kernel utility subsystems in DragonFly BSD that
don't fit into other major categories. These utilities provide essential support
functions used throughout the kernel.

## Overview

| Utility | Source | Purpose |
|---------|--------|---------|
| CPU Topology | `subr_cpu_topology.c` | CPU hierarchy detection and management |
| Event Handlers | `subr_eventhandler.c` | Generic kernel event notification |
| Unit Number Allocation | `subr_unit.c` | Efficient unit number management |
| Variant Symlinks (varsym) | `kern_varsym.c` | Variable substitution in symlinks |
| Extended I/O (XIO) | `kern_xio.c` | Page-based buffer management |

## CPU Topology

The CPU topology subsystem (`subr_cpu_topology.c`) detects and manages the
hierarchical structure of CPUs in multi-core and multi-socket systems.

### Topology Levels

```c
/* Topology hierarchy from top to bottom */
#define PACKAGE_LEVEL   0   /* Physical package/socket */
#define CHIP_LEVEL      1   /* Physical chip (socket) */
#define CORE_LEVEL      2   /* Physical core */
#define THREAD_LEVEL    3   /* Logical thread (HT/SMT) */
```

### cpu_node_t Structure

Each node in the topology tree (`subr_cpu_topology.c:63`):

```c
struct cpu_node {
    cpu_node_t      *parent_node;           /* Parent in tree */
    cpu_node_t      *child_node[MAXCPU];    /* Children */
    int             child_no;               /* Number of children */
    cpumask_t       members;                /* CPUs in this node */
    uint8_t         type;                   /* Level type */
    uint8_t         compute_unit_id;        /* AMD compute unit */
    long            phys_mem;               /* NUMA: memory attached */
};
```

### Topology Detection

The system builds a tree representing CPU relationships:

```
                  PACKAGE (root)
                       │
         ┌─────────────┼─────────────┐
         │             │             │
      CHIP 0        CHIP 1        CHIP 2
         │             │             │
    ┌────┴────┐   ┌────┴────┐   ┌────┴────┐
  CORE 0   CORE 1 CORE 0  CORE 1 CORE 0  CORE 1
    │         │     │       │     │       │
  THR 0,1  THR 0,1 ...     ...   ...     ...
```

### API Functions

```c
/* Get CPU node by CPU ID */
cpu_node_t *get_cpu_node_by_cpuid(int cpuid);

/* Get CPU node by chip ID */
const cpu_node_t *get_cpu_node_by_chipid(int chip_id);

/* Get sibling mask at specified level */
cpumask_t get_cpumask_from_level(int cpuid, uint8_t level_type);

/* Get CPU IDs */
int get_cpu_ht_id(int cpuid);       /* Thread ID within core */
int get_cpu_core_id(int cpuid);     /* Core ID within chip */
int get_cpu_phys_id(int cpuid);     /* Physical package ID */

/* NUMA support */
long get_highest_node_memory(void);  /* Highest memory on any node */
```

### Sysctl Interface

The topology is exposed via sysctl:

```
hw.cpu_topology.tree              - ASCII tree diagram
hw.cpu_topology.level_description - Level meaning
hw.cpu_topology.members           - All CPUs in system
hw.cpu_topology.cpu0.physical_id  - Package ID for CPU 0
hw.cpu_topology.cpu0.core_id      - Core ID for CPU 0
hw.cpu_topology.cpu0.physical_siblings - CPUs in same package
hw.cpu_topology.cpu0.core_siblings - CPUs in same core
```

### Global Variables

```c
/* Available after SI_BOOT2_CPU_TOPOLOGY */
int cpu_topology_levels_number;    /* 2, 3, or 4 levels */
int cpu_topology_ht_ids;           /* Threads per core */
int cpu_topology_core_ids;         /* Cores per chip */
int cpu_topology_phys_ids;         /* Physical packages */
cpu_node_t *root_cpu_node;         /* Root of topology tree */
```

## Event Handler Framework

The event handler framework (`subr_eventhandler.c`) provides a generic mechanism
for registering callbacks that are invoked when specific events occur.

### Event Lists

Events are organized in named lists:

```c
struct eventhandler_list {
    TAILQ_HEAD(, eventhandler_entry) el_entries;  /* Handlers */
    char            *el_name;                      /* Event name */
    int             el_flags;                      /* State flags */
    TAILQ_ENTRY(eventhandler_list) el_link;       /* Global list */
};
```

### Registration

```c
#include <sys/eventhandler.h>

/* Register a handler */
eventhandler_tag
eventhandler_register(struct eventhandler_list *list,
                      const char *name,
                      void *func,
                      void *arg,
                      int priority);

/* Deregister a handler */
void
eventhandler_deregister(struct eventhandler_list *list,
                        eventhandler_tag tag);

/* Find a list by name */
struct eventhandler_list *
eventhandler_find_list(const char *name);
```

### Priority Ordering

Handlers are invoked in priority order (lower first):

```c
/* Standard priorities */
#define EVENTHANDLER_PRI_FIRST      0
#define EVENTHANDLER_PRI_ANY        10000
#define EVENTHANDLER_PRI_LAST       20000
```

### Common Events

| Event | Arguments | When Invoked |
|-------|-----------|--------------|
| `shutdown_pre_sync` | `(void *arg, int howto)` | Before filesystem sync |
| `shutdown_post_sync` | `(void *arg, int howto)` | After sync, before halt |
| `shutdown_final` | `(void *arg, int howto)` | Final shutdown |
| `process_exit` | `(void *arg, struct proc *p)` | Process termination |
| `process_fork` | `(void *arg, struct proc *p1, struct proc *p2, int flags)` | Fork |

### Usage Example

```c
/* Handler function */
static void
mydev_shutdown(void *arg, int howto)
{
    struct mydev_softc *sc = arg;
    mydev_flush(sc);
}

/* Register during attach */
sc->shutdown_tag = EVENTHANDLER_REGISTER(shutdown_pre_sync,
    mydev_shutdown, sc, SHUTDOWN_PRI_DEFAULT);

/* Deregister during detach */
EVENTHANDLER_DEREGISTER(shutdown_pre_sync, sc->shutdown_tag);
```

## Unit Number Allocation

The unit allocator (`subr_unit.c`) provides efficient allocation of unit numbers
for devices and other resources using a mixed run-length/bitmap approach.

### Design Goals

- Lowest free number first policy
- Memory-efficient for sparse allocations
- O(1) allocation in common cases
- Thread-safe with optional custom locking

### Data Structures

```c
/* Unit range header */
struct unrhdr {
    TAILQ_HEAD(, unr)   head;       /* List of ranges */
    u_int               low;        /* Lowest valid unit */
    u_int               high;       /* Highest valid unit */
    u_int               busy;       /* Allocated count */
    u_int               alloc;      /* Memory block count */
    u_int               first;      /* Units allocated from start */
    u_int               last;       /* Units free at end */
    struct lock         *lock;      /* Locking */
};

/* Range element (run-length or bitmap) */
struct unr {
    TAILQ_ENTRY(unr)    list;
    u_int               len;        /* Length or bitmap count */
    void                *ptr;       /* NULL=free, unrhdr=alloc, else bitmap */
};
```

### Memory Efficiency

The allocator automatically optimizes storage:

- **Ideal split**: Just tracks first allocated and last free counts
- **Run-length**: Consecutive free/allocated ranges stored as count
- **Bitmap**: Mixed regions use compact bitmaps

Memory usage examples:
- Single contiguous run: 44 bytes (x86)
- 1000 units, random pattern: ~252 bytes worst case
- Worst case (alternating): 44 + N/4 bytes

### API

```c
/* Create a new unit number space */
struct unrhdr *new_unrhdr(int low, int high, struct lock *lock);

/* Delete a unit number space */
void delete_unrhdr(struct unrhdr *uh);

/* Allocate a unit number (with locking) */
int alloc_unr(struct unrhdr *uh);

/* Allocate with lock already held */
int alloc_unrl(struct unrhdr *uh);

/* Free a unit number */
void free_unr(struct unrhdr *uh, u_int item);
```

### Usage Example

```c
static struct unrhdr *mydev_units;

/* Initialize unit allocator */
static void
mydev_init(void)
{
    mydev_units = new_unrhdr(0, MAXUNITS - 1, NULL);
}

/* Allocate a unit */
static int
mydev_attach(device_t dev)
{
    int unit = alloc_unr(mydev_units);
    if (unit < 0)
        return ENOMEM;
    /* Use unit number... */
    return 0;
}

/* Free a unit */
static int
mydev_detach(device_t dev)
{
    free_unr(mydev_units, sc->unit);
    return 0;
}
```

## Variant Symlinks (varsym)

The variant symlink subsystem (`kern_varsym.c`) provides variable storage and
substitution for variant symlinks and general-purpose variables.

### Variable Scopes

Variables exist at different scope levels:

| Level | Scope | Description |
|-------|-------|-------------|
| `VARSYM_PROC` | Process | Per-process variables |
| `VARSYM_USER` | User | Per-user (UID) variables |
| `VARSYM_PRISON` | Jail | Per-jail variables |
| `VARSYM_SYS` | System | System-wide variables |

### Variable Substitution

When resolving symlinks, `${variable}` patterns are substituted:

```c
/* Called from namei during symlink resolution */
int varsymreplace(char *cp, int linklen, int maxlen);
```

Example symlink: `/home/${USER}/data` resolves to `/home/john/data`

### Data Structures

```c
struct varsym {
    int             vs_refs;        /* Reference count */
    int             vs_namelen;     /* Name length */
    char            *vs_name;       /* Variable name */
    char            *vs_data;       /* Variable value */
};

struct varsymset {
    TAILQ_HEAD(, varsyment) vx_queue;   /* Variables in set */
    struct lock     vx_lock;            /* Lock */
    int             vx_setsize;         /* Total size */
};
```

### System Calls

```c
/* Set a variable */
int sys_varsym_set(int level, const char *name, const char *data);

/* Get a variable */
int sys_varsym_get(int mask, const char *wild, char *buf, int bufsize);

/* List variables */
int sys_varsym_list(int level, char *buf, int maxsize, int *marker);
```

### Kernel API

```c
/* Find a variable (returns held reference) */
varsym_t varsymfind(int mask, const char *name, int namelen);

/* Drop reference */
void varsymdrop(varsym_t sym);

/* Create/delete variable */
int varsymmake(int level, const char *name, const char *data);

/* Initialize variable set */
void varsymset_init(struct varsymset *vss, struct varsymset *copy);

/* Clean variable set */
void varsymset_clean(struct varsymset *vss);
```

### Search Order

Variable lookup searches scopes in order:

1. Process scope (`VARSYM_PROC_MASK`)
2. User scope (`VARSYM_USER_MASK`)
3. Prison scope (if jailed) or System scope (`VARSYM_SYS_MASK`)

### Limits

```c
#define MAXVARSYM_NAME  64      /* Maximum variable name length */
#define MAXVARSYM_DATA  256     /* Maximum variable data length */
#define MAXVARSYM_SET   16384   /* Maximum total size per set */
```

## Extended I/O (XIO)

The XIO subsystem (`kern_xio.c`) provides a page-based buffer abstraction that
can represent memory from any address space without requiring KVM mappings.

### Design

XIO buffers are:
- **Vmspace agnostic** - Can represent user or kernel memory
- **Not KVM mapped** - Low overhead for passing between threads
- **Page-based** - Collection of held vm_page_t references

### xio_t Structure

```c
struct xio {
    int             xio_flags;      /* State flags */
    int             xio_bytes;      /* Valid bytes */
    int             xio_error;      /* Error code */
    int             xio_offset;     /* Offset in first page */
    int             xio_npages;     /* Number of pages */
    vm_page_t       *xio_pages;     /* Page array */
    vm_page_t       xio_internal_pages[XIO_INTERNAL_PAGES];
};

/* Flags */
#define XIOF_WRITE      0x0001      /* Pages may be modified */
```

### Initialization

```c
/* Initialize empty XIO */
void xio_init(xio_t xio);

/* Initialize from kernel buffer */
int xio_init_kbuf(xio_t xio, void *kbase, size_t kbytes);

/* Initialize from page array */
int xio_init_pages(xio_t xio, struct vm_page **mbase,
                   int npages, int xflags);
```

### Data Transfer

```c
/* Copy between XIO and UIO */
int xio_uio_copy(xio_t xio, int uoffset, struct uio *uio, size_t *sizep);

/* XIO to userspace */
int xio_copy_xtou(xio_t xio, int uoffset, void *uptr, int bytes);

/* Userspace to XIO */
int xio_copy_utox(xio_t xio, int uoffset, const void *uptr, int bytes);

/* XIO to kernel */
int xio_copy_xtok(xio_t xio, int uoffset, void *kptr, int bytes);

/* Kernel to XIO */
int xio_copy_ktox(xio_t xio, int uoffset, const void *kptr, int bytes);
```

### Cleanup

```c
/* Release XIO resources (unholds pages) */
void xio_release(xio_t xio);
```

### Usage Example

```c
/* Create XIO from kernel buffer */
xio_t xio;
char kbuf[4096];

xio_init(&xio);
if (xio_init_kbuf(&xio, kbuf, sizeof(kbuf)) == 0) {
    /* Pass xio to another thread/function */
    do_io_with_xio(&xio);
    
    /* Copy data back to userspace */
    xio_copy_xtou(&xio, 0, user_ptr, xio.xio_bytes);
    
    xio_release(&xio);
}
```

## Additional Utility Files

### Kernel Printf (subr_prf.c)

Implements kernel print functions:

```c
int kprintf(const char *fmt, ...);      /* Kernel printf */
int ksnprintf(char *buf, size_t size, const char *fmt, ...);
int kvprintf(const char *fmt, __va_list ap);
void log(int level, const char *fmt, ...);  /* Syslog logging */
```

### Kernel Log (subr_log.c)

Provides the `/dev/klog` interface for syslogd:

- Kernel message buffer management
- Log message priorities
- Poll/select support for log device

### Profiling (subr_prof.c)

Kernel profiling support:

```c
void addupc_intr(struct proc *p, u_long pc, u_int ticks);
void addupc_task(struct proc *p, u_long pc, u_int ticks);
```

### Power Management (subr_power.c)

Basic power management hooks:

```c
int power_pm_get_type(void);
void power_pm_suspend(int type);
void power_pm_resume(void);
```

### Scanf (subr_scanf.c)

Kernel implementations of scanf-like parsing:

```c
int ksscanf(const char *buf, const char *fmt, ...);
int kvsscanf(const char *buf, const char *fmt, __va_list ap);
```

### UUID (kern_uuid.c)

UUID generation and manipulation:

```c
void kern_uuidgen(struct uuid *store, int count);
int snprintf_uuid(char *buf, size_t sz, struct uuid *uuid);
int parse_uuid(const char *str, struct uuid *uuid);
int uuidcmp(struct uuid *a, struct uuid *b);
```

## DragonFly-Specific Features

### CPU Topology

- **AMD Compute Units**: Special handling for AMD's module architecture
- **NUMA Support**: Memory-per-node tracking for scheduler optimization
- **Dynamic Detection**: Topology built at boot from APIC information

### Variant Symlinks

- **Hierarchical Scopes**: Process → User → Jail → System lookup order
- **Jail Integration**: Per-jail variable sets
- **Dynamic Substitution**: Variables resolved at symlink traversal time

### XIO Buffers

- **Zero-Copy Paths**: Designed for efficient I/O without unnecessary copies
- **LWBUF Integration**: Uses lightweight buffer mapping for page access
- **Page Hold Semantics**: Pages held (not wired) for efficiency

## See Also

- [LWKT Threading](lwkt.md) - Thread and CPU management
- [Synchronization](synchronization.md) - Locking primitives
- [Shutdown & Panic](shutdown.md) - Event handler usage
- [Sysctl Framework](sysctl.md) - Sysctl interface implementation
