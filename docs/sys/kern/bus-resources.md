# Bus Resource Management and DMA

This document covers the resource manager (rman) subsystem for managing
hardware resources and the bus DMA subsystem for DMA memory management.

**Source files:**
- `sys/kern/subr_rman.c` - Resource manager implementation (~735 lines)
- `sys/kern/subr_busdma.c` - Bus DMA helper functions (~144 lines)
- `sys/platform/pc64/x86_64/busdma_machdep.c` - x86_64 DMA implementation (~1470 lines)
- `sys/sys/rman.h` - Resource manager data structures
- `sys/sys/bus_dma.h` - Bus DMA interface
- `sys/cpu/x86_64/include/bus_dma.h` - Architecture-specific types

## Resource Manager (rman)

The resource manager provides generic infrastructure for tracking and
allocating hardware resources like IRQs, I/O ports, and memory regions.
It is used by NewBus to manage bus resources.

### Data Structures

#### struct resource

Represents an allocated resource:

```c
struct resource {
    TAILQ_ENTRY(resource)   r_link;         /* list linkage */
    LIST_ENTRY(resource)    r_sharelink;    /* sharing list link */
    LIST_HEAD(, resource)   *r_sharehead;   /* head of sharing list */
    u_long  r_start;        /* first index in resource */
    u_long  r_end;          /* last index (inclusive) */
    u_int   r_flags;        /* RF_* flags */
    void    *r_virtual;     /* virtual address */
    bus_space_tag_t r_bustag;       /* bus_space tag */
    bus_space_handle_t r_bushandle; /* bus_space handle */
    device_t r_dev;         /* owning device */
    struct  rman *r_rm;     /* owning resource manager */
    int     r_rid;          /* resource identifier */
};
```

Defined in `sys/sys/rman.h:98-111`.

#### struct rman

The resource manager:

```c
struct rman {
    struct  resource_head   rm_list;    /* list of resources */
    struct  lwkt_token      *rm_slock;  /* mutex for rm_list */
    TAILQ_ENTRY(rman)       rm_link;    /* link in global list */
    u_long  rm_start;       /* globally first entry */
    u_long  rm_end;         /* globally last entry */
    enum    rman_type rm_type;  /* RMAN_ARRAY or RMAN_GAUGE */
    const   char *rm_descr; /* text description */
    int     rm_cpuid;       /* owner CPU ID */
    int     rm_hold;        /* destruction interlock */
};
```

Defined in `sys/sys/rman.h:115-125`.

### Resource Types

```c
enum rman_type { RMAN_UNINIT = 0, RMAN_GAUGE, RMAN_ARRAY };
```

- `RMAN_ARRAY` - Sequential, individually-allocatable resources (common case)
- `RMAN_GAUGE` - Fungible resources like power budgets (not currently used)

Defined in `sys/sys/rman.h:60`.

### Resource Flags

| Flag | Value | Description |
|------|-------|-------------|
| `RF_ALLOCATED` | 0x0001 | Resource has been reserved |
| `RF_ACTIVE` | 0x0002 | Resource allocation activated |
| `RF_SHAREABLE` | 0x0004 | Permits contemporaneous sharing |
| `RF_TIMESHARE` | 0x0008 | Permits time-division sharing |
| `RF_WANTED` | 0x0010 | Someone is waiting for resource |
| `RF_FIRSTSHARE` | 0x0020 | First in sharing list |
| `RF_PREFETCHABLE` | 0x0040 | Memory is prefetchable |
| `RF_OPTIONAL` | 0x0080 | For bus_alloc_resources() |

Alignment can be encoded in flags using:
```c
#define RF_ALIGNMENT_SHIFT  10
#define RF_ALIGNMENT_LOG2(x) ((x) << RF_ALIGNMENT_SHIFT)
#define RF_ALIGNMENT(x)     (((x) & RF_ALIGNMENT_MASK) >> RF_ALIGNMENT_SHIFT)
```

Defined in `sys/sys/rman.h:45-58`.

### API Functions

#### rman_init

Initializes a resource manager:

```c
int rman_init(struct rman *rm, int cpuid);
```

- Creates a per-rman lwkt_token for locking
- Adds the rman to global `rman_head` list
- Sets `rm_type` to `RMAN_ARRAY`

See `sys/kern/subr_rman.c:86-116`.

#### rman_manage_region

Adds a range of resources to the manager:

```c
int rman_manage_region(struct rman *rm, u_long start, u_long end);
```

- Maintains sorted order by start address
- Does NOT check for overlapping regions
- Caller must ensure regions don't overlap

See `sys/kern/subr_rman.c:122-152`.

#### rman_reserve_resource

Reserves resources from the manager:

```c
struct resource *rman_reserve_resource(struct rman *rm, u_long start,
                                       u_long end, u_long count,
                                       u_int flags, device_t dev);
```

**Allocation algorithm:**
1. Search for unshared region that fits the request
2. Split region into 1-3 parts as needed:
   - Allocating from beginning: split into 2 parts
   - Allocating from end: split into 2 parts
   - Allocating from middle: split into 3 parts
3. If `RF_SHAREABLE` or `RF_TIMESHARE`, search for exact match
4. If `RF_ACTIVE` specified, atomically activate

See `sys/kern/subr_rman.c:204-404`.

#### rman_activate_resource / rman_deactivate_resource

Activate or deactivate a resource:

```c
int rman_activate_resource(struct resource *r);
int rman_deactivate_resource(struct resource *r);
```

- Activation marks resource as `RF_ACTIVE`
- Time-shared resources: only one active at a time
- Deactivation wakes waiters via `wakeup(r->r_sharehead)`

See `sys/kern/subr_rman.c:406-515`.

#### rman_release_resource

Releases a resource back to the pool:

```c
int rman_release_resource(struct resource *r);
```

**Merging algorithm:**
1. If sharing list exists, update the list
2. Try to merge with previous adjacent segment
3. Try to merge with next adjacent segment
4. If both neighbors are free, merge all three
5. If neither neighbor is free, just mark as unallocated

See `sys/kern/subr_rman.c:517-613`.

#### rman_fini

Destroys a resource manager:

```c
int rman_fini(struct rman *rm);
```

- Fails if any resources are still allocated
- Waits for `rm_hold` to drop to zero before destroying

See `sys/kern/subr_rman.c:154-202`.

### Helper Macros

Accessor macros for resource fields:

```c
#define rman_get_start(r)       ((r)->r_start)
#define rman_get_end(r)         ((r)->r_end)
#define rman_get_size(r)        ((r)->r_end - (r)->r_start + 1)
#define rman_get_device(r)      ((r)->r_dev)
#define rman_get_flags(r)       ((r)->r_flags)
#define rman_get_virtual(r)     ((r)->r_virtual)
#define rman_get_bustag(r)      ((r)->r_bustag)
#define rman_get_bushandle(r)   ((r)->r_bushandle)
#define rman_get_rid(r)         ((r)->r_rid)
#define rman_get_cpuid(r)       ((r)->r_rm->rm_cpuid)
```

Defined in `sys/sys/rman.h:141-157`.

### Sysctl Interface

Resource manager information is exported via `hw.bus.rman` sysctl for
userspace introspection. The exported structures are:

```c
struct u_rman {
    uintptr_t      rm_handle;
    char           rm_descr[RM_TEXTLEN];
    u_long         rm_start;
    u_long         rm_size;
    enum rman_type rm_type;
};

struct u_resource {
    uintptr_t r_handle;
    uintptr_t r_parent;
    uintptr_t r_device;
    char      r_devname[RM_TEXTLEN];
    u_long    r_start;
    u_long    r_size;
    u_int     r_flags;
};
```

Defined in `sys/sys/rman.h:70-88`.

## Bus DMA Subsystem

The bus DMA subsystem provides portable DMA memory management with support
for devices that have address limitations requiring bounce buffers.

### Data Structures

#### bus_dma_tag_t (struct bus_dma_tag)

Defines constraints for DMA operations:

```c
struct bus_dma_tag {
    bus_size_t      alignment;      /* required alignment */
    bus_size_t      boundary;       /* boundary that segments can't cross */
    bus_addr_t      lowaddr;        /* low address constraint */
    bus_addr_t      highaddr;       /* high address constraint */
    bus_size_t      maxsize;        /* maximum mapping size */
    u_int           nsegments;      /* max number of segments */
    bus_size_t      maxsegsz;       /* max size per segment */
    int             flags;          /* BUS_DMA_* flags */
    int             map_count;      /* number of active maps */
    bus_dma_segment_t *segments;    /* segment array */
    struct bounce_zone *bounce_zone;/* bounce buffer zone */
    struct spinlock spin;           /* lock for segment array */
};
```

Defined in `sys/platform/pc64/x86_64/busdma_machdep.c:64-77`.

#### bus_dmamap_t (struct bus_dmamap)

Tracks a DMA mapping:

```c
struct bus_dmamap {
    struct bp_list  bpages;         /* list of bounce pages */
    int             pagesneeded;    /* pages needed for transfer */
    int             pagesreserved;  /* pages currently reserved */
    bus_dma_tag_t   dmat;           /* associated tag */
    void            *buf;           /* original buffer pointer */
    bus_size_t      buflen;         /* original buffer length */
    bus_dmamap_callback_t *callback;/* completion callback */
    void            *callback_arg;  /* callback argument */
    STAILQ_ENTRY(bus_dmamap) links; /* waitlist linkage */
};
```

Defined in `sys/platform/pc64/x86_64/busdma_machdep.c:140-150`.

#### bus_dma_segment_t

Describes a DMA segment:

```c
typedef struct bus_dma_segment {
    bus_addr_t  ds_addr;    /* DMA address */
    bus_size_t  ds_len;     /* length of transfer */
} bus_dma_segment_t;
```

Defined in `sys/sys/bus_dma.h:146-149`.

#### bus_dmamem_t

Convenience structure for coherent memory:

```c
typedef struct bus_dmamem {
    bus_dma_tag_t   dmem_tag;       /* tag used */
    bus_dmamap_t    dmem_map;       /* map created */
    void            *dmem_addr;     /* virtual address */
    bus_addr_t      dmem_busaddr;   /* bus address */
} bus_dmamem_t;
```

Defined in `sys/sys/bus_dma.h:151-156`.

### DMA Flags

| Flag | Value | Description |
|------|-------|-------------|
| `BUS_DMA_WAITOK` | 0x0000 | Safe to sleep (pseudo-flag) |
| `BUS_DMA_NOWAIT` | 0x0001 | Not safe to sleep |
| `BUS_DMA_ALLOCNOW` | 0x0002 | Perform resource allocation now |
| `BUS_DMA_COHERENT` | 0x0004 | Map memory to not require sync |
| `BUS_DMA_ZERO` | 0x0008 | Allocate zero'd memory |
| `BUS_DMA_ONEBPAGE` | 0x0100 | Allocate one bounce page per map |
| `BUS_DMA_ALIGNED` | 0x0200 | Memory is already properly aligned |
| `BUS_DMA_PRIVBZONE` | 0x0400 | Need private bounce zone |
| `BUS_DMA_ALLOCALL` | 0x0800 | Allocate all needed resources |
| `BUS_DMA_PROTECTED` | 0x1000 | Functions are already protected |
| `BUS_DMA_KEEP_PG_OFFSET` | 0x2000 | Preserve page offset in first segment |
| `BUS_DMA_NOCACHE` | 0x4000 | Map memory uncached |

Defined in `sys/sys/bus_dma.h:83-104`.

### Sync Operations

```c
typedef int bus_dmasync_op_t;
#define BUS_DMASYNC_PREREAD     0x01  /* before device reads from memory */
#define BUS_DMASYNC_POSTREAD    0x02  /* after device reads from memory */
#define BUS_DMASYNC_PREWRITE    0x04  /* before device writes to memory */
#define BUS_DMASYNC_POSTWRITE   0x08  /* after device writes to memory */
```

On x86, these operations primarily handle bounce buffer data copying:
- `PREWRITE`: Copy data from client buffer to bounce buffer
- `POSTREAD`: Copy data from bounce buffer to client buffer
- `PREREAD`/`POSTWRITE`: No-ops on cache-coherent x86

Defined in `sys/sys/bus_dma.h:116-121`.

### API Functions

#### bus_dma_tag_create

Creates a DMA tag with specified constraints:

```c
int bus_dma_tag_create(bus_dma_tag_t parent, bus_size_t alignment,
                       bus_size_t boundary, bus_addr_t lowaddr,
                       bus_addr_t highaddr, bus_size_t maxsize,
                       int nsegments, bus_size_t maxsegsz,
                       int flags, bus_dma_tag_t *dmat);
```

**Key behavior:**
- Validates alignment/boundary are powers of 2
- Inherits constraints from parent tag
- Sets bounce flags if `lowaddr < Maxmem` or `alignment > 1`
- Pre-allocates bounce pages if `BUS_DMA_ALLOCNOW`

See `sys/platform/pc64/x86_64/busdma_machdep.c:222-331`.

#### bus_dma_tag_destroy

Destroys a DMA tag:

```c
int bus_dma_tag_destroy(bus_dma_tag_t dmat);
```

- Fails with `EBUSY` if maps still exist
- Frees bounce zone (for private zones)
- Frees segment array and tag

See `sys/platform/pc64/x86_64/busdma_machdep.c:333-346`.

#### bus_dmamap_create

Creates a DMA map:

```c
int bus_dmamap_create(bus_dma_tag_t dmat, int flags, bus_dmamap_t *mapp);
```

- Returns NULL map if no bouncing needed
- Allocates map structure and initializes bounce page list
- Allocates bounce pages incrementally up to `max_bounce_pages`

See `sys/platform/pc64/x86_64/busdma_machdep.c:358-433`.

#### bus_dmamap_destroy

Destroys a DMA map:

```c
int bus_dmamap_destroy(bus_dma_tag_t dmat, bus_dmamap_t map);
```

- Fails with `EBUSY` if bounce pages still attached
- Decrements `map_count` on tag

See `sys/platform/pc64/x86_64/busdma_machdep.c:439-449`.

#### bus_dmamem_alloc

Allocates DMA-safe memory:

```c
int bus_dmamem_alloc(bus_dma_tag_t dmat, void **vaddr, int flags,
                     bus_dmamap_t *mapp);
```

**Allocation method selection:**
- Small allocations (`maxsize <= PAGE_SIZE`, `lowaddr >= Maxmem`): `kmalloc`
- Large/constrained allocations: `contigmalloc`

The map pointer encodes which allocator was used for later freeing.

See `sys/platform/pc64/x86_64/busdma_machdep.c:480-546`.

#### bus_dmamem_free

Frees DMA-safe memory:

```c
void bus_dmamem_free(bus_dma_tag_t dmat, void *vaddr, bus_dmamap_t map);
```

- `map == NULL`: uses `kfree`
- `map == (void *)-1`: uses `contigfree`

See `sys/platform/pc64/x86_64/busdma_machdep.c:552-565`.

#### bus_dmamap_load

Loads a buffer for DMA:

```c
int bus_dmamap_load(bus_dma_tag_t dmat, bus_dmamap_t map, void *buf,
                    bus_size_t buflen, bus_dmamap_callback_t *callback,
                    void *callback_arg, int flags);
```

**Algorithm:**
1. Count bounce pages needed
2. Reserve bounce pages with zone lock held
3. Per-page loop:
   - Extract physical address
   - If needs bouncing, substitute bounce page address
   - Coalesce contiguous segments
   - Handle boundary and `maxsegsz` constraints
4. If insufficient bounce pages, return `EINPROGRESS` (deferred)
5. Otherwise call callback immediately with segments

**Bounce page need determination:**
```c
static __inline int addr_needs_bounce(bus_dma_tag_t dmat, bus_addr_t paddr)
{
    if ((paddr > dmat->lowaddr && paddr <= dmat->highaddr) ||
         (bounce_alignment && (paddr & (dmat->alignment - 1)) != 0))
        return (1);
    return (0);
}
```

See `sys/platform/pc64/x86_64/busdma_machdep.c:766-807`.

#### Specialized Load Functions

**bus_dmamap_load_mbuf()** - Loads an mbuf chain:
```c
int bus_dmamap_load_mbuf(bus_dma_tag_t dmat, bus_dmamap_t map,
                         struct mbuf *m0,
                         bus_dmamap_callback2_t *callback,
                         void *callback_arg, int flags);
```
See `sys/platform/pc64/x86_64/busdma_machdep.c:836-867`.

**bus_dmamap_load_mbuf_segment()** - Loads mbuf with direct segment return:
```c
int bus_dmamap_load_mbuf_segment(bus_dma_tag_t dmat, bus_dmamap_t map,
                                 struct mbuf *m0,
                                 bus_dma_segment_t *segs, int maxsegs,
                                 int *nsegs, int flags);
```
See `sys/platform/pc64/x86_64/busdma_machdep.c:869-923`.

**bus_dmamap_load_uio()** - Loads user I/O vector:
```c
int bus_dmamap_load_uio(bus_dma_tag_t dmat, bus_dmamap_t map,
                        struct uio *uio,
                        bus_dmamap_callback2_t *callback,
                        void *callback_arg, int flags);
```
See `sys/platform/pc64/x86_64/busdma_machdep.c:928-1017`.

#### bus_dmamap_unload

Unloads a DMA mapping:

```c
void bus_dmamap_unload(bus_dma_tag_t dmat, bus_dmamap_t map);
```

- Frees all bounce pages associated with map

See `sys/platform/pc64/x86_64/busdma_machdep.c:1022-1031`.

#### bus_dmamap_sync

Synchronizes DMA memory:

```c
void bus_dmamap_sync(bus_dma_tag_t dmat, bus_dmamap_t map,
                     bus_dmasync_op_t op);
```

**Bounce buffer handling on x86:**
- `PREWRITE`: Copy data from client to bounce buffer, then `cpu_sfence()`
- `POSTREAD`: `cpu_lfence()`, then copy data from bounce to client buffer
- `PREREAD`/`POSTWRITE`: No operation (cache coherent)

See `sys/platform/pc64/x86_64/busdma_machdep.c:1033-1067`.

### Bounce Buffer Infrastructure

#### struct bounce_page

Individual bounce page:

```c
struct bounce_page {
    vm_offset_t vaddr;          /* kva of bounce buffer */
    bus_addr_t  busaddr;        /* physical address */
    vm_offset_t datavaddr;      /* kva of client data */
    bus_size_t  datacount;      /* client data count */
    STAILQ_ENTRY(bounce_page) links;
};
```

Defined in `sys/platform/pc64/x86_64/busdma_machdep.c:93-99`.

#### struct bounce_zone

Zone managing bounce pages:

```c
struct bounce_zone {
    STAILQ_ENTRY(bounce_zone) links;
    STAILQ_HEAD(bp_list, bounce_page) bounce_page_list;
    STAILQ_HEAD(, bus_dmamap) bounce_map_waitinglist;
    struct spinlock spin;
    int             total_bpages;       /* total bounce pages */
    int             free_bpages;        /* free bounce pages */
    int             reserved_bpages;    /* reserved bounce pages */
    int             active_bpages;      /* in-use bounce pages */
    int             total_bounced;      /* total transfers bounced */
    int             total_deferred;     /* total deferred operations */
    int             reserve_failed;     /* failed reservations */
    bus_size_t      alignment;          /* zone alignment */
    bus_addr_t      lowaddr;            /* zone low address limit */
    char            zoneid[8];          /* zone identifier */
    char            lowaddrid[20];      /* low address string */
    struct sysctl_ctx_list sysctl_ctx;
    struct sysctl_oid *sysctl_tree;
};
```

Defined in `sys/platform/pc64/x86_64/busdma_machdep.c:101-119`.

#### Zone Management

Bounce zones are shared by default. Multiple tags with compatible constraints
share a zone. Private zones can be requested with `BUS_DMA_PRIVBZONE`.

**alloc_bounce_zone()** - Creates or finds compatible zone:
See `sys/platform/pc64/x86_64/busdma_machdep.c:1069-1167`.

**alloc_bounce_pages()** - Allocates pages using `contigmalloc`:
See `sys/platform/pc64/x86_64/busdma_machdep.c:1169-1206`.

**reserve_bounce_pages()** - Reserves pages from free pool:
See `sys/platform/pc64/x86_64/busdma_machdep.c:1262-1283`.

**return_bounce_pages()** - Returns pages to free pool, wakes waiters:
See `sys/platform/pc64/x86_64/busdma_machdep.c:1285-1312`.

### Deferred Operations

When bounce pages are unavailable, `bus_dmamap_load()` returns `EINPROGRESS`
and the map is added to a waiting list. The `busdma_swi()` software interrupt
handler processes waiting maps when bounce pages become available.

See `sys/platform/pc64/x86_64/busdma_machdep.c:1436-1450`.

### Helper Functions

#### bus_dmamem_coherent

Allocates coherent DMA memory in one call:

```c
int bus_dmamem_coherent(bus_dma_tag_t parent,
                        bus_size_t alignment, bus_size_t boundary,
                        bus_addr_t lowaddr, bus_addr_t highaddr,
                        bus_size_t maxsize, int flags,
                        bus_dmamem_t *dmem);
```

Creates tag, allocates memory, and loads mapping.

See `sys/kern/subr_busdma.c:53-95`.

#### bus_dmamem_coherent_any

Simplified coherent allocation with no boundary:

```c
void *bus_dmamem_coherent_any(bus_dma_tag_t parent,
                              bus_size_t alignment, bus_size_t size,
                              int flags,
                              bus_dma_tag_t *dtag, bus_dmamap_t *dmap,
                              bus_addr_t *busaddr);
```

See `sys/kern/subr_busdma.c:97-117`.

#### bus_dmamap_load_mbuf_defrag

Loads mbuf with automatic defragmentation:

```c
int bus_dmamap_load_mbuf_defrag(bus_dma_tag_t dmat, bus_dmamap_t map,
                                struct mbuf **m_head,
                                bus_dma_segment_t *segs, int maxsegs,
                                int *nsegs, int flags);
```

Tries normal load first; if `EFBIG` (too many segments), defragments
the mbuf and retries.

See `sys/kern/subr_busdma.c:119-143`.

### Bus Space Operations

#### Types (x86_64)

```c
typedef uint64_t bus_addr_t;
typedef uint64_t bus_size_t;
typedef uint64_t bus_space_tag_t;
typedef uint64_t bus_space_handle_t;
```

**Bus space tags:**
- `X86_64_BUS_SPACE_IO` (0) - I/O port space
- `X86_64_BUS_SPACE_MEM` (1) - Memory-mapped space

**Address limits:**
```c
#define BUS_SPACE_MAXADDR_24BIT 0xFFFFFFUL
#define BUS_SPACE_MAXADDR_32BIT 0xFFFFFFFFUL
#define BUS_SPACE_MAXADDR       0xFFFFFFFFFFFFFFFFUL
```

Defined in `sys/cpu/x86_64/include/bus_dma.h:36-55`.

#### bus_space_map / bus_space_unmap

Maps bus space to kernel virtual address:

```c
int bus_space_map(bus_space_tag_t t, bus_addr_t addr, bus_size_t size,
                  int flags, bus_space_handle_t *bshp);
void bus_space_unmap(bus_space_tag_t t, bus_space_handle_t bsh,
                     bus_size_t size);
```

- Memory space: uses `pmap_mapdev()`/`pmap_unmapdev()`
- I/O space: returns address directly (no mapping needed)

See `sys/platform/pc64/x86_64/busdma_machdep.c:1452-1469`.

#### bus_space_barrier

Memory barrier for bus operations:

```c
static __inline void
bus_space_barrier(bus_space_tag_t tag, bus_space_handle_t bsh,
                  bus_size_t offset, bus_size_t len, int flags)
{
    if (flags & BUS_SPACE_BARRIER_READ)
        __asm __volatile("lock; addl $0,0(%%rsp)" : : : "memory");
    else
        __asm __volatile("" : : : "memory");
}
```

- Read barrier: uses locked instruction for MFENCE semantics
- Write barrier: compiler barrier only (x86 has strong ordering)

Defined in `sys/cpu/x86_64/include/bus_dma.h:893-901`.

### Sysctl Interface

**Global tunables:**
```
hw.busdma.max_bpages     - Maximum bounce pages (default 1024)
hw.busdma.bounce_alignment - Enable alignment bouncing (default 1)
```

**Per-zone statistics via `hw.busdma.zoneN.*`:**
- `total_bpages` - Total bounce pages in zone
- `free_bpages` - Free bounce pages
- `reserved_bpages` - Reserved bounce pages
- `active_bpages` - Active (in-use) bounce pages
- `total_bounced` - Total bounce operations
- `total_deferred` - Total deferred operations
- `reserve_failed` - Failed reservations
- `lowaddr` - Zone low address constraint
- `alignment` - Zone alignment constraint

## Example: DMA Buffer Allocation

```c
bus_dma_tag_t   tag;
bus_dmamap_t    map;
void            *vaddr;
bus_addr_t      paddr;
bus_dma_segment_t seg;
int             nseg;

/* Create a tag for 4K-aligned, 32-bit addressable memory */
error = bus_dma_tag_create(NULL,            /* parent */
                           4096,            /* alignment */
                           0,               /* boundary */
                           BUS_SPACE_MAXADDR_32BIT,  /* lowaddr */
                           BUS_SPACE_MAXADDR,        /* highaddr */
                           4096,            /* maxsize */
                           1,               /* nsegments */
                           4096,            /* maxsegsz */
                           0,               /* flags */
                           &tag);

/* Allocate DMA-safe memory */
error = bus_dmamem_alloc(tag, &vaddr, BUS_DMA_WAITOK | BUS_DMA_ZERO, &map);

/* Load the buffer to get physical address */
error = bus_dmamap_load(tag, map, vaddr, 4096, callback, &paddr, BUS_DMA_NOWAIT);

/* Use the buffer... */

/* Before device reads: */
bus_dmamap_sync(tag, map, BUS_DMASYNC_PREREAD);

/* After device reads: */
bus_dmamap_sync(tag, map, BUS_DMASYNC_POSTREAD);

/* Cleanup */
bus_dmamap_unload(tag, map);
bus_dmamem_free(tag, vaddr, map);
bus_dmamap_destroy(tag, map);
bus_dma_tag_destroy(tag);
```

## Cross-References

- [NewBus Framework](newbus.md) - Device/driver infrastructure using rman
- [Device Framework](devices.md) - Character device layer
- [Memory Management](memory.md) - Kernel memory allocation
- [Buffer Cache](vfs/buffer-cache.md) - BIO and buffer management
