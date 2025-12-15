# Virtual Memory Subsystem

The DragonFly BSD virtual memory subsystem manages virtual address spaces,
physical memory allocation, paging, and swap.  It derives from the Mach VM
architecture as adopted by BSD but has been extensively modified by Matthew
Dillon for better SMP scalability and LWKT integration.

## Architecture Overview

```
                    +-------------------+
                    |     vm_map        |  Virtual address space
                    |  (vm_map_entry)   |
                    +--------+----------+
                             |
                    +--------v----------+
                    |  vm_map_backing   |  Backing store chain
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

### vm_page (vm_page.h:181)

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
| `valid` | Bitmask of valid DEV_BSIZE chunks |
| `dirty` | Bitmask of dirty DEV_BSIZE chunks |
| `flags` | Page state flags (PG_MAPPED, PG_WRITEABLE, etc.) |

**Page Busy States**

Pages use a combined busy_count field with embedded flags:

- `PBUSY_LOCKED` (0x80000000) - Hard-busied, exclusive access
- `PBUSY_WANTED` (0x40000000) - Someone waiting for the page
- `PBUSY_SWAPINPROG` (0x20000000) - Swap I/O in progress
- `PBUSY_MASK` (0x1FFFFFFF) - Soft-busy reference count

A page must be hard-busied to change `object`, `pindex`, `valid`, or
to transition `wire_count` to/from zero.

### vm_object (vm_object.h:136)

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

Key fields:

```c
struct vm_object {
    struct lwkt_token token;        /* soft-lock for object */
    struct lock backing_lk;         /* lock for backing_list */
    struct vm_page_rb_tree rb_memq; /* resident pages (red-black tree) */
    vm_pindex_t size;               /* object size in pages */
    int ref_count;                  /* reference count */
    objtype_t type;                 /* pager type */
    u_short flags;                  /* OBJ_* flags */
    long resident_page_count;       /* pages in memory */
    void *handle;                   /* vnode, device, etc. */
    struct swblock_rb_tree swblock_root; /* swap block tree */
};
```

Objects are soft-locked via their `token` field using LWKT tokens,
allowing other threads to make progress during blocking operations.

**Object Flags**

- `OBJ_ACTIVE` - Object is on the active list
- `OBJ_DEAD` - Object is being destroyed
- `OBJ_WRITEABLE` - Has been mapped writable
- `OBJ_MIGHTBEDIRTY` - May contain dirty pages
- `OBJ_ONEMAPPING` - At most one mapping per page index

### vm_map (vm_map.h:337)

A `vm_map` represents a virtual address space.  The kernel has a single
`kernel_map`, while each process has its own map within a `vmspace`.

```c
struct vm_map {
    struct lock lock;               /* map lock */
    struct vm_map_rb_tree rb_root;  /* map entries (red-black tree) */
    vm_offset_t min_addr;           /* minimum valid address */
    vm_offset_t max_addr;           /* maximum valid address */
    int nentries;                   /* number of entries */
    unsigned int timestamp;         /* version for change detection */
    vm_size_t size;                 /* virtual size */
    u_char system_map;              /* kernel map flag */
    struct pmap *pmap;              /* hardware page tables */
};
```

### vm_map_entry (vm_map.h:224)

Each region in a vm_map is described by a `vm_map_entry`:

```c
struct vm_map_entry {
    RB_ENTRY(vm_map_entry) rb_entry;
    union vm_map_aux aux;           /* stack size, device, etc. */
    struct vm_map_backing ba;       /* backing store chain */
    vm_eflags_t eflags;             /* MAP_ENTRY_* flags */
    vm_maptype_t maptype;           /* NORMAL, SUBMAP, UKSMAP */
    vm_prot_t protection;           /* current protection */
    vm_prot_t max_protection;       /* maximum allowed protection */
    vm_inherit_t inheritance;       /* fork behavior */
    int wired_count;                /* wire reference count */
};
```

### vm_map_backing (vm_map.h:170)

The `vm_map_backing` structure chains backing stores for copy-on-write:

```c
struct vm_map_backing {
    vm_offset_t start;              /* start address in pmap */
    vm_offset_t end;                /* end address in pmap */
    struct pmap *pmap;              /* physical map */
    struct vm_map_backing *backing_ba; /* next in chain */
    union {
        struct vm_object *object;   /* normal backing */
        struct vm_map *sub_map;     /* submap */
        int (*uksmap)(...);         /* user-kernel shared map */
    };
    vm_ooffset_t offset;            /* offset into object */
};
```

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
```

This allows 4-way set associativity with up to 256 CPUs while reducing
lock contention on SMP systems.

## Page Fault Handling (vm_fault.c)

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

## Pager Interface (vm_pager.h)

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

## Pageout Daemon (vm_pageout.c)

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

Pages move active -> inactive when `act_count` drops sufficiently.

## Memory Thresholds (vm_page2.h)

Inline functions check memory pressure:

```c
vm_paging_severe()  /* User processes should stall */
vm_paging_min()     /* Normal faults should block */
vm_paging_wait()    /* Allocations should slow down */
vm_paging_start()   /* Pageout daemon should run */
vm_paging_target1() /* Below initial target */
vm_paging_target2() /* Below final target */
```

These use per-CPU cached statistics (`gd->gd_vmstats`) to avoid
global cache-line bouncing on the hot path.

## Kernel Memory Allocation (vm_kern.c)

Kernel memory allocation functions:

| Function | Description |
|----------|-------------|
| `kmem_alloc()` | Allocate wired kernel memory |
| `kmem_alloc3()` | With flags (KM_STACK, etc.) |
| `kmem_alloc_wait()` | Block until memory available |
| `kmem_alloc_attr()` | With physical address constraints |
| `kmem_free()` | Free kernel memory |
| `kmem_suballoc()` | Create sub-map from parent |

## vmspace (vm_map.h:370)

Process address spaces are managed via `vmspace`:

```c
struct vmspace {
    struct vm_map vm_map;       /* the address map */
    struct pmap vm_pmap;        /* private physical map */
    caddr_t vm_shm;             /* SysV shared memory */
    segsz_t vm_tsize;           /* text size (bytes) */
    segsz_t vm_dsize;           /* data size (bytes) */
    segsz_t vm_ssize;           /* stack size (bytes) */
    caddr_t vm_taddr;           /* text address */
    caddr_t vm_daddr;           /* data address */
    caddr_t vm_maxsaddr;        /* max stack address */
};
```

Key operations:

- `vmspace_alloc()` - Create new address space
- `vmspace_fork()` - Fork address space (COW)
- `vmspace_exec()` - Replace address space on exec
- `vmspace_free()` - Destroy address space

## Protection and Inheritance

### Protection Flags (vm.h)

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

## SMP Considerations

The VM subsystem uses several locking strategies for SMP scalability:

1. **LWKT Tokens** - Soft locks on vm_objects allowing blocking
2. **Spinlocks** - Per-page and per-queue spinlocks
3. **Per-CPU Statistics** - Cached vmstats avoid global contention
4. **Page Coloring** - Reduces queue lock contention
5. **Shared Faults** - `vm_shared_fault` enables shared object locks

The `vm_fault_bypass()` fast path can resolve faults with no locks at
all for pages already in the active queue.

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `vm_fault.c` | ~2,600 | Page fault handling |
| `vm_map.c` | ~3,800 | Address space management |
| `vm_object.c` | ~1,400 | VM object management |
| `vm_page.c` | ~3,300 | Physical page management |
| `vm_pageout.c` | ~2,400 | Page daemon and reclamation |
| `swap_pager.c` | ~2,000 | Swap I/O |
| `vnode_pager.c` | ~700 | File-backed I/O |
| `vm_kern.c` | ~500 | Kernel memory allocation |
| `vm_mmap.c` | ~1,100 | mmap() implementation |
| `vm_zone.c` | ~700 | Zone allocator |

## Related Documentation

- [Memory Allocation](../kern/memory.md) - kmalloc/objcache
- [Buffer Cache](../kern/vfs/buffer-cache.md) - Filesystem buffers
- [Processes](../kern/processes.md) - Process and vmspace lifecycle

## References

- `sys/vm/vm.h` - Core VM types and constants
- `sys/vm/vm_page.h` - Page structure and queues
- `sys/vm/vm_object.h` - Object structure
- `sys/vm/vm_map.h` - Map and entry structures
- `sys/vm/vm_pager.h` - Pager interface
