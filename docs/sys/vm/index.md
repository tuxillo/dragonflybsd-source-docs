# Virtual Memory Subsystem

The DragonFly BSD virtual memory subsystem manages virtual address spaces,
physical memory allocation, paging, and swap.  It derives from the Mach VM
architecture as adopted by BSD but has been extensively modified by Matthew
Dillon for better SMP scalability and LWKT integration.

## Architecture Overview

```
                    +-------------------+
                    |     vmspace       |  Per-process address space
                    | (vm_map + pmap)   |
                    +--------+----------+
                             |
                    +--------v----------+
                    |      vm_map       |  Virtual address space
                    |  (vm_map_entry)   |
                    +--------+----------+
                             |
                    +--------v----------+
                    |  vm_map_backing   |  Backing store chain (DragonFly)
                    +--------+----------+
                             |
                    +--------v----------+
                    |    vm_object      |  Container for pages
                    +--------+----------+
                             |
              +--------------+--------------+
              |              |              |
       +------v------+ +-----v------+ +-----v------+
       |   vm_page   | |  vm_page   | |  vm_page   |
       | (resident)  | | (resident) | | (swapped)  |
       +-------------+ +------------+ +-----+------+
                                            |
                                     +------v------+
                                     | swap_pager  |
                                     +-------------+
```

## Key Data Structures

### vm_page (`vm_page.h:181`)

The `vm_page` structure represents a single physical page of memory.  Each
page is 128 bytes (consuming about 3.125% overhead for 4KB pages) and
contains:

| Field | Description |
|-------|-------------|
| `pageq` | Links page into one of the page queues |
| `rb_entry` | Red-black tree entry for object lookup |
| `spin` | Per-page spinlock for queue operations |
| `wire_count` | Number of wired references |
| `busy_count` | Soft-busy and hard-busy state |
| `hold_count` | Temporary hold preventing free |
| `object` | Owning vm_object |
| `pindex` | Page index within object |
| `phys_addr` | Physical address |
| `queue` | Current queue (PQ_FREE, PQ_ACTIVE, etc.) |
| `pc` | Page color for cache optimization |
| `act_count` | Activity count (0-64) for LRU |
| `pat_mode` | Hardware page attribute (PAT) |
| `valid` | Bitmask of valid DEV_BSIZE chunks |
| `dirty` | Bitmask of dirty DEV_BSIZE chunks |
| `flags` | Page state flags (PG_MAPPED, PG_WRITEABLE, etc.) |

#### Page Busy States

Pages use a combined `busy_count` field with embedded flags:

| Flag | Value | Description |
|------|-------|-------------|
| `PBUSY_LOCKED` | 0x80000000 | Hard-busied, exclusive access |
| `PBUSY_WANTED` | 0x40000000 | Someone waiting for the page |
| `PBUSY_SWAPINPROG` | 0x20000000 | Swap I/O in progress |
| `PBUSY_MASK` | 0x1FFFFFFF | Soft-busy reference count |

A page must be hard-busied to change `object`, `pindex`, `valid`, or
to transition `wire_count` to/from zero.  Soft-busy is sufficient for
setting `PG_WRITEABLE` or `PG_MAPPED`.

#### Page Flags

| Flag | Value | Description |
|------|-------|-------------|
| `PG_FICTITIOUS` | 0x08 | Not in vm_page_array (device mappings) |
| `PG_WRITEABLE` | 0x10 | Might be writeable in some pte |
| `PG_MAPPED` | 0x20 | Might be mapped in some pmap |
| `PG_MAPPEDMULTI` | 0x40 | Multiple mappings exist |
| `PG_REFERENCED` | 0x80 | Page has been accessed |
| `PG_CLEANCHK` | 0x100 | Check during cleaning scans |
| `PG_NOSYNC` | 0x400 | Do not collect for syncer |
| `PG_UNQUEUED` | 0x800 | Prevent queue management |
| `PG_MARKER` | 0x1000 | Queue scan marker (fake page) |
| `PG_RAM` | 0x2000 | Read-ahead marker |
| `PG_SWAPPED` | 0x4000 | Page backed by swap |
| `PG_NOTMETA` | 0x8000 | Not metadata, don't back with swap |
| `PG_WINATCFLS` | 0x04 | Second chance on inactive queue |
| `PG_NEED_COMMIT` | 0x40000 | Needs remote commit (NFS) |

### vm_object (`vm_object.h:136`)

A `vm_object` is a container that holds a set of pages indexed by
`pindex` (page index).  Objects can be backed by various pagers:

| Type | Description |
|------|-------------|
| `OBJT_DEFAULT` | Anonymous memory (zero-fill on demand) |
| `OBJT_SWAP` | Swap-backed anonymous memory |
| `OBJT_VNODE` | File-backed pages |
| `OBJT_DEVICE` | Device memory mappings |
| `OBJT_MGTDEVICE` | Managed device pages |
| `OBJT_PHYS` | Direct physical memory |
| `OBJT_DEAD` | Destroyed object |
| `OBJT_MARKER` | Marker for list iteration |

Key fields:

```c
struct vm_object {
    struct lwkt_token token;        /* soft-lock for object */
    struct lock backing_lk;         /* lock for backing_list only */
    TAILQ_HEAD(, vm_map_backing) backing_list; /* who references us */
    struct vm_page_rb_tree rb_memq; /* resident pages (red-black tree) */
    int generation;                 /* generation ID for iteration */
    vm_pindex_t size;               /* object size in pages */
    int ref_count;                  /* reference count */
    vm_memattr_t memattr;           /* default memory attribute */
    objtype_t type;                 /* pager type */
    u_short flags;                  /* OBJ_* flags */
    u_short pg_color;               /* color of first page */
    u_int paging_in_progress;       /* activity counter (PIP) */
    long resident_page_count;       /* pages in memory */
    void *handle;                   /* vnode, device, etc. */
    int hold_count;                 /* destruction prevention */
    struct swblock_rb_tree swblock_root; /* swap block tree */
    long swblock_count;             /* number of swap blocks */
};
```

Objects are soft-locked via their `token` field using LWKT tokens,
allowing other threads to make progress during blocking operations.

#### Object Flags

| Flag | Value | Description |
|------|-------|-------------|
| `OBJ_ACTIVE` | 0x04 | Object is on the active list |
| `OBJ_DEAD` | 0x08 | Object is being destroyed |
| `OBJ_NOSPLIT` | 0x10 | Don't split this object |
| `OBJ_NOPAGEIN` | 0x40 | No vm_pages expected (vn/tmpfs swap-only) |
| `OBJ_WRITEABLE` | 0x80 | Has been mapped writable |
| `OBJ_MIGHTBEDIRTY` | 0x100 | May contain dirty pages |
| `OBJ_CLEANING` | 0x200 | Cleaning in progress |
| `OBJ_DEADWNT` | 0x1000 | Waiting for object death |
| `OBJ_ONEMAPPING` | 0x2000 | At most one mapping per page index |
| `OBJ_NOMSYNC` | 0x4000 | Disable msync() syscall |

**Note:** `OBJ_ONEMAPPING` only applies to DEFAULT and SWAP objects and
cannot be re-set just because `ref_count == 1` due to shared `vm_map_backing`
chains.

### vm_map (`vm_map.h:337`)

A `vm_map` represents a virtual address space.  The kernel has a single
`kernel_map`, while each process has its own map within a `vmspace`.

```c
struct vm_map {
    struct lock lock;               /* lockmgr lock (hard lock) */
    struct vm_map_rb_tree rb_root;  /* map entries (red-black tree) */
    vm_offset_t min_addr;           /* minimum valid address */
    vm_offset_t max_addr;           /* maximum valid address */
    int nentries;                   /* number of entries */
    unsigned int timestamp;         /* version for change detection */
    vm_size_t size;                 /* virtual size */
    u_char system_map;              /* kernel map flag */
    vm_flags_t flags;               /* MAP_WIREFUTURE, etc. */
    vm_map_freehint_t freehint[VM_MAP_FFCOUNT]; /* hole-finding hints */
    struct pmap *pmap;              /* hardware page tables */
    struct vm_map_ilock *ilock_base; /* range interlocks */
    struct spinlock ilock_spin;     /* spinlock for interlocks */
    struct lwkt_token token;        /* soft serializer */
    vm_offset_t pgout_offset;       /* for RLIMIT_RSS scans */
};
```

The map supports dual locking: `lock` (lockmgr) for structural changes,
`token` (LWKT) for soft serialization.  The `timestamp` is incremented
on each exclusive lock acquisition.

#### Freehint Optimization

The `freehint[]` array (4 entries) optimizes `vm_map_findspace()` by
tracking known holes.  Each hint guarantees no compatible hole exists
before its `start` address, reducing search time for large maps.

### vm_map_entry (`vm_map.h:224`)

Each region in a vm_map is described by a `vm_map_entry`:

```c
struct vm_map_entry {
    RB_ENTRY(vm_map_entry) rb_entry;
    union vm_map_aux aux;           /* stack size, device, etc. */
    struct vm_map_backing ba;       /* backing store chain (embedded) */
    vm_eflags_t eflags;             /* MAP_ENTRY_* flags */
    vm_maptype_t maptype;           /* NORMAL, SUBMAP, UKSMAP */
    vm_prot_t protection;           /* current protection */
    vm_prot_t max_protection;       /* maximum allowed protection */
    vm_inherit_t inheritance;       /* fork behavior */
    int wired_count;                /* wire reference count */
    vm_subsys_t id;                 /* subsystem identifier (debugging) */
};
```

#### Entry Flags

| Flag | Value | Description |
|------|-------|-------------|
| `MAP_ENTRY_NOSYNC` | 0x01 | Don't sync |
| `MAP_ENTRY_STACK` | 0x02 | Stack mapping |
| `MAP_ENTRY_COW` | 0x04 | Copy-on-write enabled |
| `MAP_ENTRY_NEEDS_COPY` | 0x08 | Needs copy before write |
| `MAP_ENTRY_NOFAULT` | 0x10 | No fault handling |
| `MAP_ENTRY_USER_WIRED` | 0x20 | User wired |
| `MAP_ENTRY_BEHAV_NORMAL` | 0x00 | Default access pattern |
| `MAP_ENTRY_BEHAV_SEQUENTIAL` | 0x40 | Expect sequential access |
| `MAP_ENTRY_BEHAV_RANDOM` | 0x80 | Expect random access |
| `MAP_ENTRY_IN_TRANSITION` | 0x100 | Entry being modified |
| `MAP_ENTRY_NEEDS_WAKEUP` | 0x200 | Waiters present |
| `MAP_ENTRY_NOCOREDUMP` | 0x400 | Exclude from core dumps |
| `MAP_ENTRY_KSTACK` | 0x800 | Guarded kernel stack |

#### Map Types

| Type | Value | Description |
|------|-------|-------------|
| `VM_MAPTYPE_NORMAL` | 1 | Standard mapping |
| `VM_MAPTYPE_SUBMAP` | 3 | Nested map |
| `VM_MAPTYPE_UKSMAP` | 4 | User-kernel shared memory |

### vm_map_backing (`vm_map.h:170`) — DragonFly-Specific

The `vm_map_backing` structure is DragonFly's approach to shadow object
chains.  Unlike traditional BSD where `vm_map_entry` directly points to
`vm_object`, DragonFly interposes this structure to enable:

- Efficient shadow chains without modifying `vm_object`
- Per-entry backing relationships not shared across pmaps
- Cumulative offset calculation through the chain

```c
struct vm_map_backing {
    vm_offset_t start;              /* start address in pmap */
    vm_offset_t end;                /* end address in pmap */
    struct pmap *pmap;              /* for vm_object extents */
    struct vm_map_backing *backing_ba; /* next in shadow chain */
    TAILQ_ENTRY(vm_map_backing) entry; /* linked to object's backing_list */
    union {
        struct vm_object *object;   /* normal backing */
        struct vm_map *sub_map;     /* submap */
        int (*uksmap)(struct vm_map_backing *, int op,
                      struct cdev *, vm_page_t); /* UKSMAP callback */
        void *map_object;           /* generic */
    };
    void *aux_info;
    vm_ooffset_t offset;            /* offset into object (cumulative) */
    uint32_t flags;
    uint32_t backing_count;         /* entries backing us */
};
```

The `backing_ba` pointer chains to the next backing store (shadow object).
Each object maintains a `backing_list` of all `vm_map_backing` structures
referencing it, protected by `backing_lk`.

#### UKSMAP (User-Kernel Shared Memory)

UKSMAP allows devices to provide user-kernel shared memory with a callback:

```c
int (*uksmap)(struct vm_map_backing *ba, int op,
              struct cdev *dev, vm_page_t fake);
```

Operations: `UKSMAPOP_ADD`, `UKSMAPOP_REM`, `UKSMAPOP_FAULT`

The device can map different content even after `fork()` since UKSMAPs
are unmanaged (no backing object).

## Page Queues

Pages are organized into queues based on their state.  DragonFly uses
page coloring with 1024 sub-queues per major queue for cache optimization
and reduced lock contention:

| Queue | Constant | Description |
|-------|----------|-------------|
| Free | `PQ_FREE` | Available for immediate allocation |
| Inactive | `PQ_INACTIVE` | Candidates for reclamation (LRU) |
| Active | `PQ_ACTIVE` | Recently referenced pages |
| Cache | `PQ_CACHE` | Clean pages, quickly reclaimable |
| Hold | `PQ_HOLD` | Temporarily held pages |

Queue operations require both the page's spinlock (`m->spin`) and the
queue's spinlock.  The pageout daemon has special permission to reorder
pages within a queue holding only the queue lock.

### Page Coloring

Page coloring spreads allocations across CPU cache sets:

```c
#define PQ_L2_SIZE 1024     /* sub-queues per major queue */
#define PQ_L2_MASK (PQ_L2_SIZE - 1)
#define PQ_PRIME1 31        /* hash distribution */
#define PQ_PRIME2 23
```

This allows 4-way set associativity with up to 256 CPUs while reducing
lock contention on SMP systems.  Each `struct vpgqueues` is 64-byte
aligned to prevent false sharing:

```c
struct vpgqueues {
    struct spinlock spin;
    struct pglist pl;       /* page list */
    long lcnt;              /* local count */
    long adds;              /* heuristic for add operations */
    int cnt_offset;         /* offset into vmstats */
    int lastq;              /* heuristic for skipping empty queues */
} __aligned(64);
```

### Page Allocation Flags

| Flag | Value | Description |
|------|-------|-------------|
| `VM_ALLOC_NORMAL` | 0x01 | Can use cache pages |
| `VM_ALLOC_SYSTEM` | 0x02 | Can exhaust most of free list |
| `VM_ALLOC_INTERRUPT` | 0x04 | Can exhaust entire free list |
| `VM_ALLOC_ZERO` | 0x08 | Request pre-zeroed page |
| `VM_ALLOC_QUICK` | 0x10 | Like NORMAL but skip cache |
| `VM_ALLOC_FORCE_ZERO` | 0x20 | Zero even if already valid |
| `VM_ALLOC_NULL_OK` | 0x40 | OK to return NULL on collision |
| `VM_ALLOC_RETRY` | 0x80 | Block indefinitely |
| `VM_ALLOC_USE_GD` | 0x100 | Use per-globaldata cache |
| `VM_ALLOC_CPU_SPEC` | 0x200 | CPU-specific allocation |

## Page Fault Handling (`vm_fault.c`)

The `vm_fault()` function handles page faults:

```
vm_fault(map, vaddr, fault_type, fault_flags)
    |
    +-- vm_map_lookup() - Find map entry and backing object
    |
    +-- vm_fault_bypass() - Try lockless fast path
    |       |
    |       +-- vm_page_hash_get() - Get page if already active
    |
    +-- vm_fault_object() - Full fault processing
            |
            +-- Allocate page if needed
            +-- Call pager if page not resident
            +-- Handle copy-on-write
            +-- pmap_enter() - Install mapping
```

### Fast Path (vm_fault_bypass)

For common cases where the page is already resident and active,
`vm_fault_bypass()` can resolve the fault without acquiring any
object locks:

1. Look up page via hash table with only soft-busy
2. Verify page is valid, active, and not swapped
3. For writes, verify object is already writable and page dirty
4. Install pmap mapping and return

This significantly improves performance for shared mappings like
libraries.

### Copy-on-Write

When a writable mapping needs COW:

1. Allocate new page in the first (shadow) object
2. Copy contents from backing object's page
3. Mark new page dirty
4. Update pmap to point to new page

The `vm_map_backing` chain handles the object hierarchy.

### Fault Flags

| Flag | Value | Description |
|------|-------|-------------|
| `VM_FAULT_NORMAL` | 0x00 | Standard fault |
| `VM_FAULT_CHANGE_WIRING` | 0x01 | Change wiring |
| `VM_FAULT_USER_WIRE` | 0x02 | User wire operation |
| `VM_FAULT_BURST` | 0x04 | Burst fault allowed |
| `VM_FAULT_DIRTY` | 0x08 | Dirty the page |
| `VM_FAULT_UNSWAP` | 0x10 | Remove swap backing |
| `VM_FAULT_BURST_QUICK` | 0x20 | Shared object burst |
| `VM_FAULT_USERMODE` | 0x40 | Usermode fault |

## Pager Interface (`vm_pager.h`)

Pagers provide backing store for vm_objects:

```c
struct pagerops {
    pgo_dealloc_t *pgo_dealloc;     /* destroy pager */
    pgo_getpage_t *pgo_getpage;     /* read page from backing store */
    pgo_putpages_t *pgo_putpages;   /* write pages to backing store */
    pgo_haspage_t *pgo_haspage;     /* check if page exists */
};
```

### Pager Types

| Pager | File | Description |
|-------|------|-------------|
| default | `default_pager.c` | Zero-fill pages (OBJT_DEFAULT) |
| swap | `swap_pager.c` | Swap device I/O |
| vnode | `vnode_pager.c` | File-backed I/O |
| device | `device_pager.c` | Device memory mapping |
| phys | `phys_pager.c` | Direct physical pages |

### Pager Return Values

| Value | Meaning |
|-------|---------|
| `VM_PAGER_OK` | Operation successful |
| `VM_PAGER_BAD` | Invalid request |
| `VM_PAGER_FAIL` | Data doesn't exist |
| `VM_PAGER_PEND` | I/O initiated, not complete |
| `VM_PAGER_ERROR` | I/O error |
| `VM_PAGER_AGAIN` | Temporary resource shortage |

## Pageout Daemon (`vm_pageout.c`)

The pageout daemon (`vm_pageout`) reclaims memory when free pages
fall below thresholds.  DragonFly uses a tiered threshold system:

```
reserved < severe < minimum < wait < start < target1 < target2
```

| Threshold | Effect |
|-----------|--------|
| `v_free_reserved` | Only interrupt allocations allowed |
| `v_free_severe` | User processes stall |
| `v_free_min` | Normal faults block, pageout active |
| `v_paging_wait` | Nice-based throttling |
| `v_paging_start` | Pageout daemon starts |
| `v_paging_target1` | Pageout works hard |
| `v_paging_target2` | Pageout takes it easy |

The daemon:

1. Scans inactive queue for clean pages to free
2. Writes dirty pages to backing store
3. Moves pages from active to inactive based on `act_count`
4. Uses per-CPU statistics to avoid cache-line bouncing

### Page Activity Tracking

Each page has an `act_count` (0-64) tracking recent usage:

- `ACT_INIT` (5) - Initial value for new pages
- `ACT_ADVANCE` (3) - Added on reference
- `ACT_DECLINE` (1) - Subtracted during scans
- `ACT_MAX` (64) - Maximum value

Pages move active → inactive when `act_count` drops sufficiently.

## Memory Thresholds (`vm_page2.h`)

Inline functions check memory pressure using per-CPU cached statistics
(`gd->gd_vmstats`) to avoid global cache-line bouncing:

```c
vm_paging_severe()      /* User processes should stall */
vm_paging_min()         /* Normal faults should block */
vm_paging_min_dnc(n)    /* min() but don't count n pages as free */
vm_paging_min_nice(n)   /* Nice-aware: higher nice = earlier blocking */
vm_paging_wait()        /* Allocations should slow down */
vm_paging_start(adj)    /* Pageout daemon should run */
vm_paging_target1()     /* Below initial target */
vm_paging_target2()     /* Below final target */
vm_paging_inactive()    /* Need to deactivate pages */
```

### Per-CPU Statistics Caching

Each CPU maintains local statistics in `gd->gd_vmstats_adj`, which are
periodically rolled up into the global `vmstats`.  Critical path checks
use `gd->gd_vmstats` to avoid cache mastership changes that would limit
aggregate fault rates on multi-socket systems.

## Kernel Memory Allocation (`vm_kern.c`)

Kernel memory allocation functions:

| Function | Description |
|----------|-------------|
| `kmem_alloc()` | Allocate wired kernel memory |
| `kmem_alloc3()` | With flags (KM_STACK, etc.) |
| `kmem_alloc_wait()` | Block until memory available |
| `kmem_alloc_attr()` | With physical address constraints |
| `kmem_free()` | Free kernel memory |
| `kmem_suballoc()` | Create sub-map from parent |

## vmspace (`vm_map.h:370`)

Process address spaces are managed via `vmspace`:

```c
struct vmspace {
    struct vm_map vm_map;       /* the address map (embedded) */
    struct pmap vm_pmap;        /* private physical map (embedded) */
    int vm_flags;               /* VMSPACE_EXIT1, VMSPACE_EXIT2 */
    caddr_t vm_shm;             /* SysV shared memory */
    segsz_t vm_rssize;          /* resident set size (pages) */
    segsz_t vm_swrss;           /* RSS before last swap */
    segsz_t vm_tsize;           /* text size (bytes) */
    segsz_t vm_dsize;           /* data size (bytes) */
    segsz_t vm_ssize;           /* stack size (bytes) */
    caddr_t vm_taddr;           /* text address */
    caddr_t vm_daddr;           /* data address */
    caddr_t vm_maxsaddr;        /* max stack address */
    caddr_t vm_minsaddr;        /* min stack address */
    int vm_pagesupply;
    u_int vm_holdcnt;           /* hold count (exit sequencing) */
    u_int vm_refcnt;            /* reference count */
};
```

The `vm_holdcnt` and `vm_refcnt` use `VM_REF_DELETED` (0x80000000) as
a flag to mark the vmspace as deleted.

Key operations:

- `vmspace_alloc()` - Create new address space
- `vmspace_fork()` - Fork address space (COW)
- `vmspace_exec()` - Replace address space on exec
- `vmspace_free()` - Destroy address space

### Resident Executables (`vmresident`)

DragonFly supports snapshotting a process's VM state after dynamic
linking completes:

```c
struct vmresident {
    struct vnode *vr_vnode;         /* associated vnode (locked) */
    TAILQ_ENTRY(vmresident) vr_link;
    struct vmspace *vr_vmspace;     /* vmspace to fork */
    intptr_t vr_entry_addr;         /* registered entry point */
    struct sysentvec *vr_sysent;    /* system call vectors */
    int vr_id;                      /* registration id */
    int vr_refs;                    /* temporary refs */
};
```

Future execs of the same binary skip the ELF loader and all shared
library mapping/relocation, calling the registered entry point directly.

## Protection and Inheritance

### Protection Flags (`vm.h`)

```c
#define VM_PROT_NONE     0x00
#define VM_PROT_READ     0x01
#define VM_PROT_WRITE    0x02
#define VM_PROT_EXECUTE  0x04
#define VM_PROT_OVERRIDE_WRITE  0x08  /* Force COW */
#define VM_PROT_NOSYNC   0x10         /* Don't sync dirty bit */
```

### Inheritance Modes

```c
#define VM_INHERIT_SHARE    0  /* Share mapping with child */
#define VM_INHERIT_COPY     1  /* Copy-on-write (default) */
#define VM_INHERIT_NONE     2  /* Don't inherit */
```

### Memory Attributes (`vm_memattr_t`)

Memory attributes map to x86 PAT (Page Attribute Table):

| Attribute | Description |
|-----------|-------------|
| `VM_MEMATTR_UNCACHEABLE` | No caching |
| `VM_MEMATTR_WRITE_COMBINING` | Write combining |
| `VM_MEMATTR_WRITE_THROUGH` | Write through cache |
| `VM_MEMATTR_WRITE_PROTECTED` | Write protected |
| `VM_MEMATTR_WRITE_BACK` | Write back (default) |
| `VM_MEMATTR_WEAK_UNCACHEABLE` | Weak uncacheable |

## SMP Considerations

The VM subsystem uses several locking strategies for SMP scalability:

### Locking Hierarchy

1. **LWKT Tokens** - Soft locks on vm_objects allowing blocking
2. **lockmgr Locks** - Hard locks on vm_map for structural changes
3. **Spinlocks** - Per-page (`m->spin`) and per-queue spinlocks
4. **Per-CPU Statistics** - Cached vmstats avoid global contention

### Key Optimizations

1. **Page Coloring** (1024 queues) - Reduces queue lock contention
2. **Shared Faults** (`vm_shared_fault`) - Enables shared object locks
3. **Fast Path** (`vm_fault_bypass`) - Lockless for active pages
4. **Freehint** - Reduces vm_map_findspace() iterations
5. **Per-CPU vmstats** - Avoids cache-line bouncing on hot paths

### Range Interlocks

The `vm_map_ilock` structure provides address range interlocks for
operations like `MADV_INVAL`:

```c
struct vm_map_ilock {
    struct vm_map_ilock *next;
    int flags;              /* ILOCK_WAITING */
    vm_offset_t ran_beg;
    vm_offset_t ran_end;    /* non-inclusive */
};
```

## Subsystem Identifiers

For debugging, each `vm_map_entry` has a `vm_subsys_t id` field tracking
its origin:

- `VM_SUBSYS_KMALLOC`, `VM_SUBSYS_STACK`, `VM_SUBSYS_MMAP`
- `VM_SUBSYS_BRK`, `VM_SUBSYS_SHMEM`, `VM_SUBSYS_PIPE`
- `VM_SUBSYS_DRM`, `VM_SUBSYS_DRM_GEM`, `VM_SUBSYS_DRM_TTM`
- `VM_SUBSYS_HAMMER`, `VM_SUBSYS_NVMM`, etc.

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `vm_fault.c` | ~3,200 | Page fault handling |
| `vm_map.c` | ~4,800 | Address space management |
| `vm_object.c` | ~2,000 | VM object management |
| `vm_page.c` | ~4,200 | Physical page management |
| `vm_pageout.c` | ~2,900 | Page daemon and reclamation |
| `swap_pager.c` | ~2,600 | Swap I/O |
| `vnode_pager.c` | ~800 | File-backed I/O |
| `vm_kern.c` | ~600 | Kernel memory allocation |
| `vm_mmap.c` | ~1,500 | mmap() implementation |
| `vm_zone.c` | ~900 | Zone allocator |

## Related Documentation

- [Memory Allocation](../kern/memory.md) - kmalloc/objcache
- [Buffer Cache](../kern/vfs/buffer-cache.md) - Filesystem buffers
- [Processes](../kern/processes.md) - Process and vmspace lifecycle

## References

- `sys/vm/vm.h` - Core VM types and constants
- `sys/vm/vm_param.h` - VM parameters and tunables
- `sys/vm/vm_page.h` - Page structure and queues
- `sys/vm/vm_page2.h` - Inline functions and paging thresholds
- `sys/vm/vm_object.h` - Object structure
- `sys/vm/vm_map.h` - Map and entry structures
- `sys/vm/vm_pager.h` - Pager interface
