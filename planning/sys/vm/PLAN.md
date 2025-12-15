# `sys/vm/` Reading and Documentation Plan

This plan organizes the DragonFly BSD VM subsystem (`sys/vm/`) into logical reading phases. The VM subsystem manages virtual memory, including physical page management, VM objects, address spaces, page faults, and paging.

---

## Hybrid Approach (5 Steps)

**IMPORTANT: Follow this workflow for each phase to avoid token exhaustion and ensure incremental progress.**

### Step 1: Read in Bounded Chunks
- Read 1000-1500 lines at a time from source files
- Never try to hold entire large files in context simultaneously

### Step 2: Take Notes in PLAN.md
- After reading each chunk, record key findings in the "Consolidated Notes" sections below
- Document: data structures, key functions, DragonFly-specific details, cross-references

### Step 3: Transform Notes to Documentation
- Once a logical section is fully read and noted, write a polished documentation file in `docs/sys/vm/`
- Use the accumulated notes - do NOT re-read source files

### Step 4: Commit Frequently
- Commit each documentation file immediately after completion
- This establishes checkpoints and prevents losing work

### Step 5: Use PLAN.md as Working Memory
- This file persists across sessions
- If approaching token limits, stop and commit progress
- Next session can resume from where notes left off

### Workflow per Phase
```
Read chunk 1 → Note in PLAN.md → 
Read chunk 2 → Note in PLAN.md → 
... →
Write docs/sys/vm/X.md from notes → 
Commit → 
Next phase
```

---

## Overview of Target Files

| File | Lines | Purpose |
|------|-------|---------|
| `vm.h` | 135 | Core VM types and constants |
| `vm_param.h` | 155 | VM parameters and tunables |
| `vm_page.h` | 577 | `struct vm_page` definition, page flags |
| `vm_page2.h` | 600 | Inline page functions, busy handling |
| `vm_object.h` | 388 | `struct vm_object` definition |
| `vm_map.h` | 654 | Address space structures (`vm_map`, `vm_map_entry`) |
| `vm_page.c` | 4,241 | Physical page management implementation |
| `vm_object.c` | 2,034 | VM object management |
| `vm_map.c` | 4,781 | Address space management |
| `vm_fault.c` | 3,243 | Page fault handling |
| `vm_pageout.c` | 2,895 | Pageout daemon |
| `swap_pager.c` | 2,600 | Swap subsystem |
| `vnode_pager.c` | 832 | File-backed page I/O |
| `vm_mmap.c` | 1,530 | mmap implementation |
| **Total** | **~24,665** | |

---

## Reading Phases

### Phase 1: Core Data Structures (Headers) ✅ COMPLETE
**Goal:** Understand fundamental VM data structures before implementations.

| Step | File(s) | Lines | Focus |
|------|---------|-------|-------|
| 1.1 | `vm.h`, `vm_param.h` | ~290 | Basic types, constants, tunables |
| 1.2 | `vm_page.h`, `vm_page2.h` | ~1,177 | `struct vm_page`, page states/flags, busy handling |
| 1.3 | `vm_object.h` | ~388 | `struct vm_object`, object types |
| 1.4 | `vm_map.h` | ~654 | `struct vm_map`, `vm_map_entry`, `vm_map_backing` |

**Output:** `docs/sys/vm/index.md` - VM architecture overview (from header notes)

---

### Phase 2: Physical Page Management (`vm_page.c`)
**Goal:** Understand physical page allocation, free lists, and state transitions.

| Step | Lines | Focus |
|------|-------|-------|
| 2.1 | 0-1500 | Page allocation, free queues, coloring |
| 2.2 | 1500-3000 | Page state transitions, busy handling |
| 2.3 | 3000-4241 | Remaining functions |

**Output:** `docs/sys/vm/vm_page.md` - Physical page management

---

### Phase 3: VM Objects (`vm_object.c`)
**Goal:** Understand VM object lifecycle and shadow chains.

| Step | Lines | Focus |
|------|-------|-------|
| 3.1 | 0-1000 | Object creation, reference counting |
| 3.2 | 1000-2034 | Shadow objects, collapse, paging |

**Output:** `docs/sys/vm/vm_object.md` - VM objects

---

### Phase 4: Address Space Management (`vm_map.c`)
**Goal:** Understand address space structures and operations.

| Step | Lines | Focus |
|------|-------|-------|
| 4.1 | 0-1500 | vmspace, map creation, entry management |
| 4.2 | 1500-3000 | Lookups, clipping, entry operations |
| 4.3 | 3000-4781 | COW, forking, protection |

**Output:** `docs/sys/vm/vm_map.md` - Address space management

---

### Phase 5: Page Fault Handling (`vm_fault.c`)
**Goal:** Understand page fault resolution and COW.

| Step | Lines | Focus |
|------|-------|-------|
| 5.1 | 0-1500 | Fault state, main entry points |
| 5.2 | 1500-3243 | Core fault logic, COW handling |

**Output:** `docs/sys/vm/vm_fault.md` - Page fault handling

---

### Phase 6: Pageout and Swap
**Goal:** Understand memory reclamation and swap management.

| Step | File | Lines | Focus |
|------|------|-------|-------|
| 6.1 | `vm_pageout.c` | 0-1500 | Pageout daemon, page scanning |
| 6.2 | `vm_pageout.c` | 1500-2895 | Page laundering, OOM |
| 6.3 | `swap_pager.c` | 0-1300 | Swap allocation, metadata |
| 6.4 | `swap_pager.c` | 1300-2600 | Swap I/O |

**Output:** `docs/sys/vm/vm_pageout.md` - Pageout daemon and swap

---

### Phase 7: Pagers and mmap
**Goal:** Understand vnode pager and mmap syscalls.

| Step | File | Lines | Focus |
|------|------|-------|-------|
| 7.1 | `vnode_pager.c` | 0-832 | File-backed page I/O |
| 7.2 | `vm_mmap.c` | 0-1530 | mmap/munmap/mprotect |

**Output:** `docs/sys/vm/vm_mmap.md` - Pagers and memory mapping

---

## Progress Tracking

| Phase | Read | Notes | Doc Written | Commit |
|-------|------|-------|-------------|--------|
| 1 (Headers) | ✅ | ✅ | ✅ | `3108069` |
| 2 (vm_page.c) | ✅ | ✅ | In Progress | - |
| 3 (vm_object.c) | Pending | Pending | Pending | - |
| 4 (vm_map.c) | Pending | Pending | Pending | - |
| 5 (vm_fault.c) | Pending | Pending | Pending | - |
| 6 (pageout/swap) | Pending | Pending | Pending | - |
| 7 (pagers/mmap) | Pending | Pending | Pending | - |

### Next Action
**Phase 2 → Read `vm_page.c` in chunks**, take notes, then write `docs/sys/vm/vm_page.md`.

---

## Consolidated Notes

### Phase 1: Core Data Structures

#### 1.1 vm.h, vm_param.h

**vm.h** (136 lines) - Core VM types and constants

Types defined:
- `vm_inherit_t` (char) - Inheritance codes for fork behavior
  - `VM_INHERIT_SHARE` (0) - Child shares mapping with parent
  - `VM_INHERIT_COPY` (1) - Child gets COW copy (default)
  - `VM_INHERIT_NONE` (2) - Mapping not inherited

- `vm_prot_t` (u_char) - Protection codes
  - `VM_PROT_NONE` (0x00)
  - `VM_PROT_READ` (0x01)
  - `VM_PROT_WRITE` (0x02)
  - `VM_PROT_EXECUTE` (0x04)
  - `VM_PROT_OVERRIDE_WRITE` (0x08) - Used for COW
  - `VM_PROT_NOSYNC` (0x10) - Skip cache sync

- `vm_maptype_t` (u_char) - Type of vm_map_entry
  - `VM_MAPTYPE_NORMAL` (1) - Standard mapping
  - `VM_MAPTYPE_SUBMAP` (3) - Nested map
  - `VM_MAPTYPE_UKSMAP` (4) - **DragonFly-specific**: User-kernel shared memory (unmanaged)

- `vm_memattr_t` (char) - Memory attributes (maps to x86 PAT)
  - `VM_MEMATTR_UNCACHEABLE`, `VM_MEMATTR_WRITE_COMBINING`
  - `VM_MEMATTR_WRITE_THROUGH`, `VM_MEMATTR_WRITE_PROTECTED`
  - `VM_MEMATTR_WRITE_BACK` (default), `VM_MEMATTR_WEAK_UNCACHEABLE`

Forward declarations: `struct vm_map_entry`, `struct vm_map`, `struct vm_object`, `struct vm_page`

**vm_param.h** (156 lines) - VM parameters and tunables

CTL_VM sysctl identifiers:
- `VM_METER` (1) - struct vmmeter
- `VM_LOADAVG` (2) - struct loadavg
- `VM_V_FREE_MIN` (3), `VM_V_FREE_TARGET` (4), `VM_V_FREE_RESERVED` (5)
- `VM_V_INACTIVE_TARGET` (6), `VM_V_PAGEOUT_FREE_MIN` (7)
- `VM_PAGEOUT_ALGORITHM` (8), `VM_SWAPPING_ENABLED` (9)
- `VM_V_PAGING_WAIT` (10), `VM_V_PAGING_START` (11)
- `VM_V_PAGING_TARGET1` (12), `VM_V_PAGING_TARGET2` (13)

`struct xswdev` - Swap device statistics (for sysctl export)
- `xsw_dev`, `xsw_blksize`, `xsw_nblks`, `xsw_used`, `xsw_flags`

KERN_* return codes:
- `KERN_SUCCESS` (0), `KERN_INVALID_ADDRESS` (1), `KERN_PROTECTION_FAILURE` (2)
- `KERN_NO_SPACE` (3), `KERN_INVALID_ARGUMENT` (4), `KERN_FAILURE` (5)
- `KERN_RESOURCE_SHORTAGE` (6), `KERN_NOT_RECEIVER` (7), `KERN_NO_ACCESS` (8)
- `KERN_TRY_AGAIN` (9), `KERN_FAILURE_NOFAULT` (10)

Size limit globals: `maxtsiz`, `dfldsiz`, `maxdsiz`, `dflssiz`, `maxssiz`, `sgrowsiz`

**DragonFly-specific notes:**
- `VM_MAPTYPE_UKSMAP` - User-kernel shared memory, unmanaged (no backing object), device can map different content even after fork()
- `VM_PROT_NOSYNC` flag for skipping cache synchronization
- Memory attributes tied to x86 PAT (Page Attribute Table)

#### 1.2 vm_page.h, vm_page2.h

**vm_page.h** (578 lines) - Core page structure and page queue definitions

`struct vm_page` (128 bytes, 3.125% memory overhead for 4K pages):
```c
struct vm_page {
    TAILQ_ENTRY(vm_page) pageq;   // queue linkage (free/active/inactive/cache)
    RB_ENTRY(vm_page) rb_entry;   // red-black tree for object lookup
    struct spinlock spin;          // per-page spinlock (queue changes only)
    struct md_page md;            // machine-dependent (pmap) data
    uint32_t wire_count;          // wired references
    uint32_t busy_count;          // soft-busy + hard-busy state
    int hold_count;               // hold count (prevents freeing)
    int ku_pagecnt;               // kmalloc helper for oversized allocs
    struct vm_object *object;     // containing object
    vm_pindex_t pindex;           // offset into object (page index)
    vm_paddr_t phys_addr;         // physical address
    uint16_t queue;               // current queue index
    uint16_t pc;                  // page color
    uint8_t act_count;            // activity count (0-64)
    uint8_t pat_mode;             // hardware page attribute (PAT)
    uint8_t valid;                // bitmap of valid DEV_BSIZE chunks
    uint8_t dirty;                // bitmap of dirty DEV_BSIZE chunks
    uint32_t flags;               // page flags (PG_*)
};
```

Busy state encoding (`busy_count` field):
- `PBUSY_LOCKED` (0x80000000) - Hard-busy (exclusive)
- `PBUSY_WANTED` (0x40000000) - Someone waiting
- `PBUSY_SWAPINPROG` (0x20000000) - Swap I/O in progress
- `PBUSY_MASK` (0x1FFFFFFF) - Soft-busy count (shared)

Page flags (PG_*):
- `PG_FICTITIOUS` (0x08) - No reverse-map, might not be in vm_page_array[]
- `PG_WRITEABLE` (0x10) - Might be writeable in some pte
- `PG_MAPPED` (0x20) - Might be mapped in some pmap
- `PG_MAPPEDMULTI` (0x40) - Multiple mappings
- `PG_REFERENCED` (0x80) - Accessed bit synchronized from pmap
- `PG_CLEANCHK` (0x100) - For detecting insertions during scans
- `PG_NOSYNC` (0x400) - Do not collect for syncer
- `PG_UNQUEUED` (0x800) - Prevent queue management
- `PG_MARKER` (0x1000) - Queue scan marker (fake page)
- `PG_RAM` (0x2000) - Read-ahead marker
- `PG_SWAPPED` (0x4000) - Page backed by swap
- `PG_NOTMETA` (0x8000) - Not metadata, don't back with swap
- `PG_WINATCFLS` (0x04) - Dirty page second chance on inactive queue
- `PG_NEED_COMMIT` (0x40000) - Clean page needs remote commit (NFS)

**Page coloring** - DragonFly-specific scalability feature:
- `PQ_L2_SIZE` = 1024 queues per queue type
- Distributes pages across queues to reduce lock contention on many-core systems
- `PQ_PRIME1` (31), `PQ_PRIME2` (23) for hash distribution
- Each CPU gets dedicated queue subsets based on color

Page queue types:
- `PQ_FREE` - Available for allocation
- `PQ_INACTIVE` - Low activity, candidates for reclamation
- `PQ_ACTIVE` - Recently referenced pages
- `PQ_CACHE` - Clean, immediately freeable
- `PQ_HOLD` - Temporarily held pages

`struct vpgqueues` (64-byte aligned):
- `spin` - Per-queue spinlock
- `pl` - Page list (TAILQ)
- `lcnt` - Local count
- `adds` - Heuristic for add operations
- `cnt_offset` - Offset into vmstats
- `lastq` - Heuristic for skipping empty queues

Allocation flags (VM_ALLOC_*):
- `VM_ALLOC_NORMAL` (0x01) - Can use cache pages
- `VM_ALLOC_SYSTEM` (0x02) - Can exhaust most of free list
- `VM_ALLOC_INTERRUPT` (0x04) - Can exhaust entire free list
- `VM_ALLOC_ZERO` (0x08) - Request pre-zeroed page
- `VM_ALLOC_QUICK` (0x10) - Like NORMAL but skip cache
- `VM_ALLOC_RETRY` (0x80) - Block indefinitely (vm_page_grab)
- `VM_ALLOC_USE_GD` (0x100) - Use per-globaldata cache
- `VM_ALLOC_CPU_SPEC` (0x200) - CPU-specific allocation

Locking rules (from header comments):
1. Hard-busy required for: object/pindex changes, wire_count 0↔non-zero, valid changes, clearing PG_MAPPED/PG_WRITEABLE
2. Soft-busy sufficient for: setting PG_WRITEABLE/PG_MAPPED
3. Unlocked: hold_count changes, PG_RAM, dirty if PG_WRITEABLE set, PG_REFERENCED if PG_MAPPED
4. Queue changes require m->spin + queue spinlock

**vm_page2.h** (601 lines) - Inline functions and paging thresholds

Per-CPU vmstats caching (SMP optimization):
- Each CPU collects adjustments in `gd->gd_vmstats_adj`
- Rolled up into global `vmstats` periodically
- Critical paths use per-CPU `gd->gd_vmstats` to avoid cache contention

Paging thresholds (ascending order):
```
reserved < severe < minimum < wait < start < target1 < target2
```

Threshold functions:
- `vm_paging_severe()` - Causes user processes to stall
- `vm_paging_min()` / `vm_paging_min_dnc()` - Activates pageout daemon, blocks faults
- `vm_paging_min_nice(nice)` - Nice-aware threshold (process priority affects blocking)
- `vm_paging_wait()` - Slow down allocations
- `vm_paging_start(adj)` - Start/continue pageout daemon
- `vm_paging_target1()` - Pageout works hard to reach this
- `vm_paging_target2()` - Pageout takes it easy between target1 and target2
- `vm_paging_inactive()` - Need to deactivate pages
- `vm_paging_inactive_count()` - How many pages need deactivation

Wire/unwire inlines:
- `vm_page_wire_quick()` - Atomic increment (must already be wired)
- `vm_page_unwire_quick()` - Refuses to drop to 0, returns TRUE if would have

Soft-busy inlines:
- `vm_page_sbusy_hold()` - Increment soft-busy count
- `vm_page_sbusy_drop()` - Decrement, wakeup if WANTED and count reaches 0

Other inlines:
- `vm_page_protect(m, prot)` - Reduce page protection (VM_PROT_NONE removes all mappings)
- `vm_page_zero_fill(m)` - Zero entire page via pmap
- `vm_page_copy(src, dest)` - Copy page contents
- `vm_page_free(m)` - Wrapper for vm_page_free_toq()
- `vm_page_undirty(m)` - Clear dirty bits (not pmap bits)
- `vm_page_flash(m)` - Wakeup waiters if PBUSY_WANTED set

Dirty bit manipulation:
- `vm_page_clear_dirty_end_nonincl()` - Clear dirty, preserve partial DEV_BSIZE at end
- `vm_page_clear_dirty_beg_nonincl()` - Clear dirty, preserve partial DEV_BSIZE at beginning

**DragonFly-specific highlights:**
1. Per-page spinlock (m->spin) only for queue changes, not general protection
2. Page coloring with 1024 queues per type for SMP scalability
3. Per-CPU vmstats caching to reduce cache line bouncing
4. Nice-aware paging thresholds (nice value affects when process blocks)
5. Soft-busy/hard-busy distinction with atomic operations
6. PBUSY_SWAPINPROG flag for swap I/O coordination
7. FICTITIOUS pages for device mappings (GPU, etc.)
8. PG_NEED_COMMIT for NFS/distributed filesystem coherency

#### 1.3 vm_object.h

**vm_object.h** (389 lines) - VM object structure and operations

Object types (`enum obj_type`):
- `OBJT_DEFAULT` - Anonymous memory (initially no backing)
- `OBJT_SWAP` - Object backed by swap blocks
- `OBJT_VNODE` - Object backed by file (vnode)
- `OBJT_DEVICE` - Object backed by device pages
- `OBJT_MGTDEVICE` - Managed device pager
- `OBJT_PHYS` - Object backed by physical pages
- `OBJT_DEAD` - Dead object (during teardown)
- `OBJT_MARKER` - Marker object for list iteration

`struct vm_object`:
```c
struct vm_object {
    struct lwkt_token token;           // soft-lock (blocking allowed)
    struct lock backing_lk;            // lock for backing_list only
    TAILQ_ENTRY(vm_object) object_entry;
    TAILQ_HEAD(, vm_map_backing) backing_list;  // who references this object
    struct vm_page_rb_tree rb_memq;    // resident pages (red-black tree)
    int generation;                    // generation ID (for iteration)
    vm_pindex_t size;                  // object size in pages
    int ref_count;                     // reference count
    vm_memattr_t memattr;              // default memory attribute for pages
    objtype_t type;                    // pager type
    u_short flags;                     // OBJ_* flags
    u_short pg_color;                  // color of first page
    u_int paging_in_progress;          // activity counter (PIP)
    long resident_page_count;          // number of resident pages
    TAILQ_ENTRY(vm_object) pager_object_entry;  // pager's list
    void *handle;                      // control handle (vp, dev, etc.)
    int hold_count;                    // destruction prevention

    union {
        struct {                       // Device pager
            TAILQ_HEAD(, vm_page) devp_pglist;
            struct cdev_pager_ops *ops;
            struct cdev *dev;
        } devp;
    } un_pager;

    struct swblock_rb_tree swblock_root;  // swap block tree
    long swblock_count;                   // number of swap blocks
    struct md_object md;                  // machine-specific (pmap)
};
```

Object flags (OBJ_*):
- `OBJ_ACTIVE` (0x04) - Object is active
- `OBJ_DEAD` (0x08) - Object is being destroyed
- `OBJ_NOSPLIT` (0x10) - Don't split this object
- `OBJ_NOPAGEIN` (0x40) - Special for OBJT_SWAP (vn/tmpfs), no vm_pages expected
- `OBJ_WRITEABLE` (0x80) - Object has been made writeable
- `OBJ_MIGHTBEDIRTY` (0x100) - Object might have dirty pages
- `OBJ_CLEANING` (0x200) - Cleaning in progress
- `OBJ_DEADWNT` (0x1000) - Waiting for object death
- `OBJ_ONEMAPPING` (0x2000) - Each page index mapped to at most one vm_map_entry
- `OBJ_NOMSYNC` (0x4000) - Disable msync() syscall

`OBJ_ONEMAPPING` notes:
- Only applies to DEFAULT and SWAP objects
- Indicates each page maps to at most one vm_map_entry
- **Cannot** be re-set just because ref_count==1 (shared vm_map_backing chains)

Page clean flags (OBJPC_*):
- `OBJPC_SYNC` (0x01) - Synchronous I/O
- `OBJPC_INVAL` (0x02) - Invalidate pages
- `OBJPC_NOSYNC` (0x04) - Skip PG_NOSYNC pages
- `OBJPC_IGNORE_CLEANCHK` (0x08) - Ignore PG_CLEANCHK flag
- `OBJPC_CLUSTER_OK` (0x10) - Clustering allowed (vnode pager)
- `OBJPC_TRY_TO_CACHE` (0x20) - Try to cache (pageout path)
- `OBJPC_ALLOW_ACTIVE` (0x40) - Allow active pages (pageout)

Global hash table:
- `VMOBJ_HSIZE` = 256 buckets
- `struct vm_object_hash` - Per-bucket list + token, cache-aligned
- `vm_object_hash[VMOBJ_HSIZE]` - Global hash array

Global objects:
- `kernel_object` - Single kernel object
- `vm_shared_fault` - Shared fault flag

Conversion macros:
- `IDX_TO_OFF(idx)` - Page index to byte offset
- `OFF_TO_IDX(off)` - Byte offset to page index

Inline functions:
- `vm_object_set_flag()` / `vm_object_clear_flag()` - Atomic flag manipulation
- `vm_object_pip_add()` - Add to paging_in_progress
- `vm_object_pip_wakeup()` / `vm_object_pip_wakeup_n()` - Decrement PIP with wakeup
- `vm_object_pip_wait()` - Wait for PIP to reach 0
- `vm_object_token()` - Get object's LWKT token

Locking:
- `VM_OBJECT_LOCK(obj)` → `vm_object_hold(obj)` - LWKT token acquisition
- `VM_OBJECT_UNLOCK(obj)` → `vm_object_drop(obj)` - Token release
- Soft-lock semantics: blocking allowed, other threads can squeeze in work

Key functions:
- `vm_object_allocate()` / `vm_object_allocate_hold()` - Create object
- `vm_object_collapse()` - Collapse shadow chains
- `vm_object_terminate()` - Destroy object
- `vm_object_page_clean()` - Clean pages in range
- `vm_object_page_remove()` - Remove pages in range
- `vm_object_reference_quick()` / `vm_object_reference_locked()` - Add reference
- `vm_object_deallocate()` / `vm_object_deallocate_locked()` - Remove reference
- `vm_object_hold()` / `vm_object_hold_shared()` - Acquire token
- `vm_object_hold_try()` - Try to acquire token (non-blocking)
- `vm_object_drop()` - Release token
- `vm_object_upgrade()` / `vm_object_downgrade()` - Token mode changes

**DragonFly-specific highlights:**
1. LWKT token-based soft-locking instead of traditional mutexes
2. Separate `backing_lk` lock just for backing_list
3. `backing_list` - TAILQ of vm_map_backing structures referencing this object
4. Swap block tree (`swblock_root`) for both OBJT_SWAP and OBJT_VNODE
5. `paging_in_progress` uses refcount primitives with wakeup
6. Cache-aligned hash buckets to reduce false sharing
7. DEBUG_LOCKS support for tracking object holders

#### 1.4 vm_map.h

**vm_map.h** (655 lines) - Address space structures and operations

Subsystem identifiers (`vm_subsys_t`) - Debugging aid for tracking map entry origins:
- `VM_SUBSYS_KMALLOC`, `VM_SUBSYS_STACK`, `VM_SUBSYS_IMGACT`, `VM_SUBSYS_EFI`
- `VM_SUBSYS_PIPE`, `VM_SUBSYS_PROC`, `VM_SUBSYS_SHMEM`, `VM_SUBSYS_MMAP`, `VM_SUBSYS_BRK`
- `VM_SUBSYS_BUF`, `VM_SUBSYS_BUFDATA`, `VM_SUBSYS_GD`, `VM_SUBSYS_IPIQ`
- `VM_SUBSYS_PVENTRY`, `VM_SUBSYS_PML4`, `VM_SUBSYS_MAPDEV`, `VM_SUBSYS_ZALLOC`
- `VM_SUBSYS_DM`, `VM_SUBSYS_CONTIG`, `VM_SUBSYS_DRM*`, `VM_SUBSYS_HAMMER`, `VM_SUBSYS_NVMM`

`union vm_map_aux` - Auxiliary data per entry type:
- `avail_ssize` - Available stack size for growth (MAP_STACK)
- `master_pde` - Virtual page table root
- `dev` - Device pointer
- `map_aux` - Generic pointer

**`struct vm_map_backing`** - DragonFly-specific backing store chain element:
```c
struct vm_map_backing {
    vm_offset_t start;              // start address in pmap
    vm_offset_t end;                // end address in pmap
    struct pmap *pmap;              // for vm_object extents
    struct vm_map_backing *backing_ba;  // backing store chain (shadow)
    TAILQ_ENTRY(vm_map_backing) entry;  // linked to object's backing_list
    union {
        struct vm_object *object;   // vm_object
        struct vm_map *sub_map;     // submap
        int (*uksmap)(...);         // user-kernel shared map callback
        void *map_object;           // generic
    };
    void *aux_info;
    vm_ooffset_t offset;            // offset into backing object
    uint32_t flags;
    uint32_t backing_count;         // number of entries backing us
};
```

Key insight: Unlike traditional BSD where vm_map_entry directly points to vm_object,
DragonFly uses `vm_map_backing` chains. This allows:
- Efficient shadow object chains without modifying vm_object
- Per-entry backing relationships not shared across pmaps
- Cumulative offset calculation through chain

`struct vm_map_entry` - Address range mapping:
```c
struct vm_map_entry {
    RB_ENTRY(vm_map_entry) rb_entry;  // red-black tree linkage
    union vm_map_aux aux;              // auxiliary data
    struct vm_map_backing ba;          // embedded backing structure
    vm_eflags_t eflags;                // entry flags
    vm_maptype_t maptype;              // VM_MAPTYPE_*
    vm_prot_t protection;              // current protection
    vm_prot_t max_protection;          // maximum protection
    vm_inherit_t inheritance;          // fork behavior
    int wired_count;                   // wiring count (0 = pageable)
    vm_subsys_t id;                    // subsystem identifier
};
```

Entry flags (MAP_ENTRY_*):
- `MAP_ENTRY_NOSYNC` (0x01) - Don't sync
- `MAP_ENTRY_STACK` (0x02) - Stack mapping
- `MAP_ENTRY_COW` (0x04) - Copy-on-write
- `MAP_ENTRY_NEEDS_COPY` (0x08) - Needs copy before write
- `MAP_ENTRY_NOFAULT` (0x10) - No fault handling
- `MAP_ENTRY_USER_WIRED` (0x20) - User wired
- `MAP_ENTRY_BEHAV_*` (0x40-0xC0) - Access pattern hints (NORMAL, SEQUENTIAL, RANDOM)
- `MAP_ENTRY_IN_TRANSITION` (0x100) - Entry being modified
- `MAP_ENTRY_NEEDS_WAKEUP` (0x200) - Waiters present
- `MAP_ENTRY_NOCOREDUMP` (0x400) - Exclude from core dumps
- `MAP_ENTRY_KSTACK` (0x800) - Guarded kernel stack

`struct vm_map_ilock` - Virtual address range interlock (for MADV_INVAL):
- `ran_beg`, `ran_end` - Address range
- `flags` - ILOCK_WAITING

`struct vm_map_freehint` - Optimization for vm_map_findspace():
- `start`, `length`, `align` - Hint parameters
- `VM_MAP_FFCOUNT` = 4 hints maintained
- Guarantees no compatible hole exists before `start`

`struct vm_map` - Address space container:
```c
struct vm_map {
    struct lock lock;                    // lockmgr lock (hard lock)
    struct vm_map_rb_tree rb_root;       // red-black tree of entries
    vm_offset_t min_addr, max_addr;      // address bounds
    int nentries;                        // entry count
    unsigned int timestamp;              // version number
    vm_size_t size;                      // virtual size
    u_char system_map;                   // kernel map flag
    u_char freehint_newindex;
    vm_flags_t flags;                    // MAP_WIREFUTURE, etc.
    vm_map_freehint_t freehint[VM_MAP_FFCOUNT];
    struct pmap *pmap;                   // physical map
    struct vm_map_ilock *ilock_base;     // range interlocks
    struct spinlock ilock_spin;          // spinlock for interlocks
    struct lwkt_token token;             // soft serializer
    vm_offset_t pgout_offset;            // for RLIMIT_RSS scans
};
```

Locking model:
- `lock` - lockmgr (hard lock) for structural changes
- `token` - LWKT token (soft serializer) for concurrent access
- Can use both simultaneously for complex operations
- `timestamp` incremented on each exclusive lock

`struct vmspace` - Per-process virtual address space:
```c
struct vmspace {
    struct vm_map vm_map;      // embedded vm_map
    struct pmap vm_pmap;       // embedded pmap (private physical map)
    int vm_flags;              // VMSPACE_EXIT1, VMSPACE_EXIT2
    caddr_t vm_shm;            // SysV shared memory private data
    // Copied on fork (from vm_startcopy):
    segsz_t vm_rssize;         // resident set size (pages)
    segsz_t vm_swrss;          // RSS before last swap
    segsz_t vm_tsize;          // text size (bytes)
    segsz_t vm_dsize;          // data size (bytes)
    segsz_t vm_ssize;          // stack size (bytes)
    caddr_t vm_taddr;          // text start address
    caddr_t vm_daddr;          // data start address
    caddr_t vm_maxsaddr;       // max stack address
    caddr_t vm_minsaddr;       // min stack address
    int vm_pagesupply;
    u_int vm_holdcnt;          // hold count (exit sequencing)
    u_int vm_refcnt;           // reference count
};
```

`VM_REF_DELETED` (0x80000000) - Marks vmspace as deleted in refcnt

`struct vmresident` - Resident executable support:
- Allows snapshotting VM state after dynamic linking
- Future execs skip ELF loading and library relocation
- Fields: `vr_vnode`, `vr_vmspace`, `vr_entry_addr`, `vr_sysent`

Map locking macros:
- `vm_map_lock(map)` - Exclusive lock, increments timestamp
- `vm_map_unlock(map)` - Release lock
- `vm_map_lock_read(map)` - Shared lock
- `vm_map_unlock_read(map)` - Release shared
- `vm_map_lock_read_try(map)` - Non-blocking shared
- `vm_map_lock_read_to(map)` - Shared with timeout
- `vm_map_lock_upgrade(map)` - Shared→Exclusive upgrade
- `vm_map_lock_downgrade(map)` - Exclusive→Shared downgrade

Copy-on-write flags (COWF_*):
- `COWF_COPY_ON_WRITE` (0x02) - Enable COW
- `COWF_NOFAULT` (0x04) - No fault handling
- `COWF_PREFAULT` (0x08) - Prefault pages
- `COWF_DISABLE_SYNCER` (0x20) - Skip syncer
- `COWF_IS_STACK` / `COWF_IS_KSTACK` (0x40/0x80) - Stack mapping
- `COWF_SHARED` (0x0800) - Shared mapping
- `COWF_32BIT` (0x1000) - 32-bit address space

VM fault flags (VM_FAULT_*):
- `VM_FAULT_NORMAL` (0x00) - Standard fault
- `VM_FAULT_CHANGE_WIRING` (0x01) - Change wiring
- `VM_FAULT_USER_WIRE` (0x02) - User wire operation
- `VM_FAULT_BURST` (0x04) - Burst fault allowed
- `VM_FAULT_DIRTY` (0x08) - Dirty the page
- `VM_FAULT_UNSWAP` (0x10) - Remove swap backing
- `VM_FAULT_BURST_QUICK` (0x20) - Shared object burst
- `VM_FAULT_USERMODE` (0x40) - Usermode fault

Bootstrap constants:
- `MAX_KMAP` = 10 (kernel maps to statically allocate)
- `MAX_MAPENT` = SMP_MAXCPU * 32 + 1024 (entries to statically allocate)

Key functions:
- `vm_map_init()` - Initialize a map
- `vm_map_find()` - Find space and insert mapping
- `vm_map_findspace()` - Find hole of given size
- `vm_map_insert()` - Insert entry at specific location
- `vm_map_delete()` / `vm_map_remove()` - Remove mappings
- `vm_map_lookup()` - Find entry for address
- `vm_map_lookup_entry()` - Lookup entry (boolean)
- `vm_map_protect()` - Change protection
- `vm_map_inherit()` - Change inheritance
- `vm_map_clean()` - Flush pages
- `vm_map_kernel_wiring()` / `vm_map_user_wiring()` - Wire/unwire
- `vm_map_madvise()` - Process madvise hints
- `vm_map_stack()` / `vm_map_growstack()` - Stack management
- `vm_map_interlock()` / `vm_map_deinterlock()` - Range interlocks

**DragonFly-specific highlights:**
1. `vm_map_backing` structure - Chains backing stores without modifying vm_object
2. Embedded `ba` in vm_map_entry (not a pointer) - single allocation
3. `backing_ba` chain for shadow objects
4. `vm_subsys_t` for debugging/tracking entry origins
5. UKSMAP support - user-kernel shared memory with callback
6. Freehint optimization - tracks known holes for faster findspace
7. Dual locking: lockmgr + LWKT token
8. Range interlocks (ilock) for MADV_INVAL
9. Resident executable support (vmresident) for fast exec
10. 32-bit address space flag (COWF_32BIT)

---

### Phase 2: Physical Page Management

**vm_page.c** (4,242 lines) - Physical page allocation and queue management

#### Global Data Structures

**Page Queues:**
- `vm_page_queues[PQ_COUNT]` - Array of `struct vpgqueues`
- 5 queue types × 1024 colors = 5120 total queues
- Each queue has its own spinlock for SMP scalability

**Page Hash Table (Heuristic Lookup):**
```c
struct vm_page_hash_elm {
    vm_page_t m;
    vm_object_t object;   // cached for fast comparison
    vm_pindex_t pindex;   // cached for fast comparison
    int ticks;            // LRU timestamp
};
```
- `VM_PAGE_HASH_SET` = 4 (4-way set associative)
- `VM_PAGE_HASH_MAX` = 8M entries maximum
- Size scales with `vm_page_array_size / 16`
- Used by `vm_page_hash_get()` for lockless lookup

**DMA Reserve:**
- `vm_contig_alist` - alist allocator for contiguous low-memory DMA pages
- `vm_low_phys_reserved` - threshold for DMA reserve (default 65536 pages)
- `vm_dma_reserved` - tunable, default 128MB on systems with 2G+ RAM
- Pages below threshold marked `PG_FICTITIOUS | PG_UNQUEUED`, wired

**Page Array:**
- `vm_page_array` - Array of all `struct vm_page` in system
- `vm_page_array_size` - Number of entries
- `first_page` - First physical page index
- `PHYS_TO_VM_PAGE(pa)` - Macro to convert physical address to vm_page

#### Boot-Time Initialization

**`vm_set_page_size()` (line 216):**
- Sets `vmstats.v_page_size` to `PAGE_SIZE` (typically 4KB)
- Called very early in boot

**`vm_page_startup()` (line 326):**
1. Rounds phys_avail[] ranges to page boundaries
2. Finds largest memory block
3. Initializes page queues via `vm_page_queue_init()`
4. Allocates minidump bitmap (`vm_page_dump`)
5. Calculates `vm_page_array` size and allocates it
6. Initializes each `struct vm_page` with spinlock and `phys_addr`
7. Adds pages to free queues via `vm_add_new_page()`
8. Low memory (< `vm_low_phys_reserved`) goes to DMA alist instead

**`vm_add_new_page()` (line 238):**
- Calculates page color with CPU twisting for NUMA locality:
  ```c
  m->pc = (pa >> PAGE_SHIFT);
  m->pc ^= ((pa >> PAGE_SHIFT) / PQ_L2_SIZE);
  m->pc ^= ((pa >> PAGE_SHIFT) / (PQ_L2_SIZE * PQ_L2_SIZE));
  m->pc &= PQ_L2_MASK;
  ```
- Pages added to HEAD of free queue (cache-hot)

**`vm_numa_organize()` (line 517):**
- Called during boot with NUMA topology info
- Reorganizes page colors based on physical socket ID
- `socket_mod = PQ_L2_SIZE / cpu_topology_phys_ids`
- `socket_value = (physid % cpu_topology_phys_ids) * socket_mod`
- Requeues pages to match socket affinity

**`vm_numa_organize_finalize()` (line 633):**
- Balances page queues after NUMA organization
- Prevents empty queues that would force cross-socket borrowing
- Calculates average pages per queue, rebalances to 90-100% of average

**`vm_page_startup_finish()` (line 745):**
- SYSINIT at `SI_SUB_PROC0_POST`
- Returns excess DMA reserve to normal free queues
- Allocates page hash table via `kmem_alloc3()`
- Sets `set_assoc_mask` based on ncpus (8-way minimum, 16-way default max)

#### Queue Spinlock Management

**Locking Order:** Page spinlock first, then queue spinlock

**`_vm_page_queue_spin_lock(m)` (line 912):**
- Locks queue spinlock while holding page spinlock
- Asserts queue hasn't changed during lock acquisition

**`_vm_page_rem_queue_spinlocked(m)` (line 1020):**
- Removes page from current queue
- Adjusts per-CPU vmstats (`mycpu->gd_vmstats_adj`)
- Synchronizes to global vmstats if adjustment gets too negative (-1024)
- Returns base queue type (PQ_FREE, PQ_CACHE, etc.)

**`_vm_page_add_queue_spinlocked(m, queue, athead)` (line 1086):**
- Adds page to specified queue
- PQ_FREE always inserted at HEAD (cache-hot)
- Other queues respect `athead` parameter

#### Page Lookup

**`vm_page_lookup()` (line 1731):**
- Requires vm_object token held
- Does RB-tree lookup in `object->rb_memq`
- Calls `vm_page_hash_enter()` on hit for future fast lookup

**`vm_page_hash_get()` (line 1601):**
- Lockless heuristic lookup
- Returns soft-busied page on success, NULL on miss
- 4-way set associative search
- Only caches pages with `PG_MAPPEDMULTI` flag

**`vm_page_lookup_busy_wait()` (line 1749):**
- Lookup + busy with blocking wait
- Sets `PBUSY_WANTED` and sleeps if page busy
- Re-lookups after wakeup (page might have moved)

**`vm_page_lookup_busy_try()` (line 1804):**
- Non-blocking lookup + busy attempt
- Returns page + error flag on busy conflict

**`vm_page_lookup_sbusy_try()` (line 1849):**
- Lookup + soft-busy for read-only access
- Validates page data before returning

#### Page Allocation

**`vm_page_alloc()` (line 2528):**
Main allocation entry point.

Flags:
- `VM_ALLOC_NORMAL` - Can use cache pages
- `VM_ALLOC_QUICK` - Free queue only, skip cache
- `VM_ALLOC_SYSTEM` - Can exhaust most of free list
- `VM_ALLOC_INTERRUPT` - Can exhaust entire free list
- `VM_ALLOC_CPU(n)` - CPU localization hint
- `VM_ALLOC_ZERO` - Zero page if allocated (vm_page_grab only)
- `VM_ALLOC_NULL_OK` - Return NULL on collision instead of panic

Algorithm:
1. Calculate `pg_color` via `vm_get_pg_color(cpuid, object, pindex)`
2. Check free count thresholds:
   - Normal: `v_free_count >= v_free_reserved`
   - System: Can dip to `v_interrupt_free_min`
   - Interrupt: Can use any free page
3. Try `vm_page_select_free()` or `vm_page_select_free_or_cache()`
4. If using cache page, free it first then retry (replenishes free count)
5. Insert into object if provided
6. Returns BUSY page

**`vm_get_pg_color()` (line 1176):**
CPU-localized page coloring algorithm:
```c
// With NUMA topology:
physcale = PQ_L2_SIZE / cpu_topology_phys_ids;
grpscale = physcale / cpu_topology_core_ids;
cpuscale = grpscale / cpu_topology_ht_ids;

pg_color = phys_id * physcale;
pg_color += core_id * grpscale;
pg_color += ht_id * cpuscale;
pg_color += (pindex + object_pg_color) % cpuscale;
```

**`_vm_page_list_find()` (line 2006):**
- Finds page on specified queue with color optimization
- Tries exact color first, then widens search
- Returns spinlocked page, removed from queue

**`_vm_page_list_find_wide()` (line 2043):**
- Widening search: 16 → 32 → 64 → 128 → ... → PQ_L2_MASK
- Tracks `lastq` to skip known-empty queues
- NUMA-aware: stays local before widening

**`vm_page_select_cache()` (line 2314):**
- Selects page from PQ_CACHE
- Deactivates page if busy or dirty

**`vm_page_select_free()` (line 2368):**
- Selects page from PQ_FREE
- Deactivates if busy (rare, from pmap_collect)

**`vm_page_alloc_contig()` (line 2764):**
- Allocates contiguous physical pages from DMA reserve
- Uses `alist_alloc()` on `vm_contig_alist`
- Returns base vm_page pointer

**`vm_page_alloczwq()` (line 3738):**
- Allocates without object association
- Returns wired, non-busy page
- Optionally zeros page

**`vm_page_grab()` (line 3824):**
- Lookup-or-allocate with object
- Blocks on busy page if `VM_ALLOC_RETRY`
- Handles `VM_ALLOC_ZERO` and `VM_ALLOC_FORCE_ZERO`

#### Page Freeing

**`vm_page_free_toq()` (line 3150):**
Main free entry point.
1. Asserts page not mapped (`pmap_mapped_sync()` if needed)
2. Removes from object via `vm_page_remove()`
3. For fictitious pages: just wakeup and return
4. Removes from current queue
5. Clears valid/dirty bits
6. If `hold_count != 0`: goes to PQ_HOLD
7. Otherwise: goes to PQ_FREE (at head for cache-hot)
8. Wakes up page waiters
9. Calls `vm_page_free_wakeup()` for memory-waiting threads

**`vm_page_free_wakeup()` (line 3103):**
- Wakes pageout daemon if it needs pages
- Wakes memory-waiting processes if above hysteresis threshold

**`vm_page_free_contig()` (line 2857):**
- Frees contiguously allocated pages
- Returns to DMA alist if in low memory region
- Otherwise unwires and frees normally

#### Page State Transitions

**Queue Transitions:**
```
PQ_FREE ←→ (allocated/freed)
    ↓
PQ_ACTIVE ←→ PQ_INACTIVE
    ↓           ↓
    └──→ PQ_CACHE ──→ PQ_FREE
              ↓
          PQ_HOLD (if held during free)
```

**`vm_page_activate()` (line 3046):**
- Moves page to PQ_ACTIVE queue
- Sets `act_count` to at least `ACT_INIT`
- Wakes pagedaemon if from PQ_CACHE/PQ_FREE

**`vm_page_deactivate()` (line 3368):**
- Moves page to PQ_INACTIVE queue
- Clears `PG_WINATCFLS` flag
- `athead` parameter for pseudo-cache behavior

**`vm_page_cache()` (line 3484):**
- Moves clean page to PQ_CACHE
- Removes all pmap mappings first
- Dirty pages get deactivated instead

**`vm_page_try_to_cache()` (line 3393):**
- Attempts to cache a busy page
- Tests dirty via `vm_page_test_dirty()`
- Unconditionally unbusies on return

**`vm_page_try_to_free()` (line 3437):**
- Attempts to free an unlocked page
- Must not be dirty, held, wired, or special

#### Busy State Management

**`vm_page_busy_wait()` (line 1270):**
- Waits for `PBUSY_LOCKED` to clear
- If `also_m_busy`: also waits for soft-busy count = 0
- Sets `PBUSY_WANTED` and sleeps

**`vm_page_busy_try()` (line 1313):**
- Non-blocking busy attempt
- Returns TRUE on failure

**`vm_page_wakeup()` (line 1366):**
- Clears `PBUSY_LOCKED` and `PBUSY_WANTED`
- Wakes waiters

**`vm_page_sleep_busy()` (line 1139):**
- Sleeps until page not busy (does not busy page)

**Soft-Busy (`vm_page_io_start/finish`, line 3637):**
- Increments/decrements `busy_count & PBUSY_MASK`
- Allows compatible operations (e.g., read-only mapping during write)

**`vm_page_sbusy_try()` (line 3668):**
- Non-blocking soft-busy acquire
- Uses cmpset to avoid racing hard-busy

#### Wire/Unwire

**`vm_page_wire()` (line 3244):**
- Increments `wire_count` atomically
- Adjusts `vmstats.v_wire_count` on 0→1 transition
- No effect on fictitious pages

**`vm_page_unwire()` (line 3293):**
- Decrements `wire_count` atomically
- On 1→0 transition:
  - Activates if `PG_NEED_COMMIT` set
  - Otherwise deactivates
  - Adjusts vmstats

#### Hold/Unhold

**`vm_page_hold()` (line 1391):**
- Prevents page from being freed
- Does NOT prevent disassociation from object

**`vm_page_unhold()` (line 1412):**
- On last unhold, moves page from PQ_HOLD to PQ_FREE

#### Page Insert/Remove

**`vm_page_insert()` (line 1476):**
- Requires object token held exclusively
- Inserts into object's RB tree
- Increments `resident_page_count`
- Sets `OBJ_WRITEABLE`/`OBJ_MIGHTBEDIRTY` if dirty
- Calls `swap_pager_page_inserted()` to check for swap

**`vm_page_remove()` (line 1536):**
- Requires page BUSY
- Removes from object's RB tree
- Decrements `resident_page_count`

**`vm_page_rename()` (line 1919):**
- Moves page between objects
- Invalidates swap backing
- Dirties the page

#### Valid/Dirty Bit Management

**Bitmap Format:**
- 8 bits per page (PAGE_SIZE / DEV_BSIZE)
- DEV_BSIZE = 512 bytes typically
- Each bit covers one 512-byte chunk

**`vm_page_bits()` (line 3902):**
- Converts (base, size) to bit mask

**`vm_page_set_valid()` (line 3995):**
- Sets valid bits, zeros invalid portions

**`vm_page_set_validclean()` (line 4014):**
- Sets valid, clears dirty

**`vm_page_dirty()` (line 4075):**
- Sets all dirty bits
- Updates object dirty flags

**`vm_page_test_dirty()` (line 4184):**
- Syncs dirty bit from pmap
- Calls `pmap_is_modified()`

**`vm_page_zero_invalid()` (line 4121):**
- Zeros invalid portions of partially valid page
- Used before mapping to userspace

#### Memory Pressure / Waiting

**`vm_wait()` (line 2926):**
- Blocks until memory available
- Nice-aware: `vm_paging_min_nice(nice + 1)`
- Wakes pageout daemon

**`vm_wait_pfault()` (line 2989):**
- Called from page fault path
- Uses process nice value directly
- Can break out if `P_LOWMEMKILL` set

**`vm_wait_nominal()` (line 2900):**
- Waits until not in paging state
- For kernel heavy memory operations

#### madvise Support

**`vm_page_dontneed()` (line 3571):**
- Implements MADV_DONTNEED
- Weighted: 3/32 deactivate, 28/32 cache (at head)
- Clears PG_REFERENCED

#### Special Pages

**Fictitious Pages:**
- `PG_FICTITIOUS` flag
- Not in normal page array
- `vm_page_initfake()` (line 1438) creates them
- Wire/unwire have no effect
- Used for device mappings

**`vm_page_need_commit()` (line 3698):**
- Sets `PG_NEED_COMMIT` for tmpfs/NFS
- Clean pages with this flag cannot be reclaimed

#### DDB Commands (Debug)

- `show page` - Display vmstats
- `show pageq` - Display queue lengths per color

---

### Phase 3: VM Objects

*(To be filled as we read vm_object.c)*

---

### Phase 4: Address Space Management

*(To be filled as we read vm_map.c)*

---

### Phase 5: Page Fault Handling

*(To be filled as we read vm_fault.c)*

---

### Phase 6: Pageout and Swap

*(To be filled as we read vm_pageout.c and swap_pager.c)*

---

### Phase 7: Pagers and mmap

*(To be filled as we read vnode_pager.c and vm_mmap.c)*

---

## DragonFly-Specific Features (Summary)

Based on Phase 1 header analysis:

### Locking Model
- **LWKT tokens** for soft-locking vm_object (blocking allowed, interleaving possible)
- **lockmgr locks** for hard-locking vm_map
- **Per-page spinlocks** (m->spin) only for queue manipulation
- **Per-CPU vmstats caching** to reduce cache line bouncing on SMP

### Page Management
- **Page coloring** with 1024 queues per type (`PQ_L2_SIZE`) for SMP scalability
- **Soft-busy/hard-busy** distinction with atomic operations (`PBUSY_*`)
- **FICTITIOUS pages** for device mappings (GPU, etc.) outside vm_page_array
- **PG_NEED_COMMIT** flag for NFS/distributed filesystem coherency
- **Nice-aware paging** thresholds (process priority affects memory blocking)

### Object Model
- **Separate backing_lk** lock just for object's backing_list
- **TAILQ of vm_map_backing** structures on each object
- **Swap blocks** stored in red-black tree, available for both OBJT_SWAP and OBJT_VNODE
- **OBJ_NOPAGEIN** for vn/tmpfs objects that only use swap, no vm_pages
- **Cache-aligned hash buckets** (256) for object lookup

### Address Space Model
- **vm_map_backing chains** instead of direct object pointers
  - Enables shadow chains without modifying vm_object
  - Cumulative offset calculation through chain
  - Per-entry backing not shared across pmaps
- **Embedded vm_map_backing** in vm_map_entry (single allocation)
- **Freehint optimization** for vm_map_findspace()
- **Range interlocks** (vm_map_ilock) for MADV_INVAL
- **vm_subsys_t identifiers** for tracking entry origins

### Special Features
- **UKSMAP** - User-kernel shared memory with device callback
- **vmresident** - Resident executable snapshots for fast exec
- **32-bit address space support** (COWF_32BIT)
- **PBUSY_SWAPINPROG** for swap I/O coordination

---

## Key Data Structures (Quick Reference)

| Structure | File | Purpose |
|-----------|------|---------|
| `struct vm_page` | vm_page.h | Physical page descriptor (128 bytes) |
| `struct vm_object` | vm_object.h | Container for pages, backing store |
| `struct vm_map` | vm_map.h | Address space (contains pmap pointer) |
| `struct vm_map_entry` | vm_map.h | Single address range mapping |
| `struct vm_map_backing` | vm_map.h | Backing store chain element |
| `struct vmspace` | vm_map.h | Process address space (vm_map + pmap) |
| `struct vpgqueues` | vm_page.h | Page queue descriptor |
| `struct vm_map_freehint` | vm_map.h | Hole-finding optimization |
| `struct vmresident` | vm_map.h | Resident executable snapshot |

---

## Important Functions (Quick Reference)

*(To be populated as we read implementation files)*

| Function | File | Purpose |
|----------|------|---------|
| `vm_page_alloc()` | vm_page.c | Allocate physical page |
| `vm_page_free()` | vm_page.c | Free physical page |
| `vm_object_allocate()` | vm_object.c | Create VM object |
| `vm_object_deallocate()` | vm_object.c | Release VM object |
| `vm_object_collapse()` | vm_object.c | Collapse shadow chains |
| `vm_map_find()` | vm_map.c | Find space and create mapping |
| `vm_map_insert()` | vm_map.c | Insert mapping at address |
| `vm_map_lookup()` | vm_map.c | Find entry for address |
| `vm_fault()` | vm_fault.c | Handle page fault |
| `vm_pageout()` | vm_pageout.c | Pageout daemon main loop |
