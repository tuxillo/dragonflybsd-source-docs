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
| 2 (vm_page.c) | ✅ | ✅ | ✅ | `cbd8cf1` |
| 3 (vm_object.c) | ✅ | ✅ | ✅ | `8f1191d` |
| 4 (vm_map.c) | ✅ | ✅ | ✅ | `9c6de88` |
| 5 (vm_fault.c) | ✅ | ✅ | ✅ | `1a02811` |
| 6 (pageout/swap) | ✅ | ✅ | ✅ | - |
| 7 (pagers/mmap) | Pending | Pending | Pending | - |

### Next Action
**Phase 7 → Read `vnode_pager.c` and `vm_mmap.c`**, take notes, then write pagers/mmap documentation.

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

**vm_object.c** (~2,034 lines) - VM object lifecycle, reference counting, and page management

#### Global Data Structures

**Hash Table:**
```c
struct vm_object_hash vm_object_hash[VMOBJ_HSIZE];  // VMOBJ_HSIZE = 256
```
- Each bucket has a TAILQ list + LWKT token
- Hash function uses two primes for distribution:
  - `VMOBJ_HASH_PRIME1` = 66555444443333333
  - `VMOBJ_HASH_PRIME2` = 989042931893
- `vmobj_hash(obj)` - Returns bucket for object pointer

**Kernel Object:**
```c
static struct vm_object kernel_object_store;
struct vm_object *kernel_object = &kernel_object_store;
```
- Single global kernel object for kernel address space
- Initialized during `vm_object_init1()`

#### Locking Functions

All locking wraps LWKT tokens (soft-locks, blocking allowed):

| Function | Description |
|----------|-------------|
| `vm_object_lock(obj)` | `lwkt_gettoken(&obj->token)` - exclusive |
| `vm_object_lock_try(obj)` | `lwkt_trytoken()` - non-blocking |
| `vm_object_lock_shared(obj)` | `lwkt_gettoken_shared()` - shared |
| `vm_object_unlock(obj)` | `lwkt_reltoken()` |
| `vm_object_upgrade(obj)` | Release + re-acquire exclusive |
| `vm_object_downgrade(obj)` | Release + re-acquire shared |
| `vm_object_lock_swap()` | `lwkt_token_swap()` |

#### Hold/Drop Functions

Hold prevents object from being freed while working with it:

**`vm_object_hold(obj)`** (line 283):
- `refcount_acquire(&obj->hold_count)` FIRST (makes object stable)
- Then `vm_object_lock(obj)` (may block)
- Must hold before blocking to prevent object being freed

**`vm_object_hold_try(obj)`** (line 302):
- Non-blocking version
- Increments hold_count, tries lock
- On failure: releases hold_count, may free if ref_count==0 && OBJ_DEAD

**`vm_object_hold_shared(obj)`** (line 328):
- Like hold but acquires shared lock

**`vm_object_drop(obj)`** (line 352):
- Releases hold_count + unlocks
- On last hold (1→0): if ref_count==0 && OBJ_DEAD, frees object
- Token might be shared at this point

#### Object Allocation

**`vm_quickcolor()`** (line 270):
- Returns semi-random page color for new objects
- Uses `gd->gd_curthread` address + `gd->gd_quick_color`
- Increments quick_color by PQ_PRIME2 (23)

**`_vm_object_allocate(type, size, obj, ident)`** (line 388):
Core initialization for all objects:
1. `RB_INIT(&object->rb_memq)` - page tree
2. `lwkt_token_init(&object->token, ident)`
3. `TAILQ_INIT(&object->backing_list)`
4. `lockinit(&object->backing_lk, "baclk", 0, 0)`
5. Sets type, size, ref_count=1, memattr=DEFAULT
6. For DEFAULT/SWAP: sets `OBJ_ONEMAPPING`
7. `pg_color = vm_quickcolor()`
8. `RB_INIT(&object->swblock_root)` - swap blocks
9. `pmap_object_init(object)` - arch-specific
10. `vm_object_hold(object)` - returns held
11. Inserts into hash table

**`vm_object_allocate(type, size)`** (line 471):
- kmalloc + `_vm_object_allocate()` + drop
- Returns dropped (unheld) object

**`vm_object_allocate_hold(type, size)`** (line 487):
- kmalloc + `_vm_object_allocate()`
- Returns HELD object for further atomic init

**`vm_object_init(obj, size)`** (line 432):
- Initializes existing object as OBJT_DEFAULT
- For use with pre-allocated objects

**`vm_object_init1()`** (line 445):
- Called during early boot (before kmalloc)
- Initializes hash table (256 buckets with tokens)
- Creates kernel_object spanning KvaEnd

**`vm_object_init2()`** (line 460):
- Post-boot: sets M_VM_OBJECT to unlimited

#### Reference Counting

**`vm_object_reference_locked(obj)`** (line 506):
- Adds reference while holding object token
- For OBJT_VNODE: also calls `vref(obj->handle)`
- Uses atomic_add_int for SMP safety

**`vm_object_reference_quick(obj)`** (line 527):
- Adds reference WITHOUT holding object
- Only safe when caller knows object is deterministically referenced
- Typical use: vnode refs, map_entry replication
- For OBJT_VNODE: also calls `vref(obj->handle)`

**`vm_object_vndeallocate(obj, vpp)`** (line 548):
- Special deref for OBJT_VNODE
- Handles ref_count atomically with retry loop
- On 1→0: upgrades to exclusive, clears VTEXT flag
- Returns vnode in *vpp for caller to vrele (or vreles if vpp==NULL)
- Complex because shared lock can race to 0 in other paths

**`vm_object_deallocate(obj)`** (line 615):
Main deref entry point (object NOT held):
- Fast path (count > 3): atomic decrement without locking
- Slow path (count <= 3): hold + `vm_object_deallocate_locked()` + drop
- For OBJT_VNODE: handles vref/vrele coordination
- Avoids exclusive lock crowbar on highly shared binaries (exec/exit)

**`vm_object_deallocate_locked(obj)`** (line 679):
- Internal deref with object held
- For OBJT_VNODE: delegates to `vm_object_vndeallocate()`
- For others: requires exclusive lock
- On 1→0: calls `vm_object_terminate()` if not OBJ_DEAD

#### Object Termination

**`vm_object_terminate(obj)`** (line 746):
Destroys object with zero refs:

1. Sets `OBJ_DEAD` flag (allows safe blocking after this)
2. `vm_object_pip_wait()` - waits for paging_in_progress == 0
3. For OBJT_VNODE:
   - `vinvalbuf()` - flush buffers
   - `vm_object_page_clean()` - clean dirty pages
   - `vinvalbuf()` again (TMPFS may not flush to swap)
4. Another `vm_object_pip_wait()`
5. `pmap_object_free()` - cleanup shared pmaps
6. Scan pages via `vm_object_terminate_callback()`:
   - Loops until all pages freed
   - Retries on busy pages
7. `vm_pager_deallocate()` - notify pager
8. Removes from hash table
9. Object freed later in `vm_object_drop()` when hold_count reaches 0

**`vm_object_terminate_callback(p, data)`** (line 878):
Per-page callback during termination:
- Tries to busy page (retries if busy)
- For unwired pages: `vm_page_protect(VM_PROT_NONE)` + `vm_page_free()`
- For wired pages: just removes from object (warning logged)
- Yields every 64 pages to avoid hogging CPU

#### Page Cleaning

**`vm_object_page_clean(obj, start, end, flags)`** (line 944):
Cleans dirty pages in range:

- Only for OBJT_VNODE with OBJ_MIGHTBEDIRTY
- Sets `OBJ_CLEANING` during operation
- Flags:
  - `OBJPC_SYNC` - synchronous I/O
  - `OBJPC_INVAL` - invalidate after clean
  - `OBJPC_NOSYNC` - skip PG_NOSYNC pages
  - `OBJPC_CLUSTER_OK` - allow clustering

**Pass 1** (`vm_object_page_clean_pass1`, line ~990):
- Marks pages read-only via `vm_page_protect(VM_PROT_READ)`
- If entire object cleaned successfully: clears OBJ_WRITEABLE|OBJ_MIGHTBEDIRTY
- Clears VISDIRTY/VOBJDIRTY on vnode

**Pass 2** (`vm_object_page_clean_pass2`, line 1063):
- Skips pages without PG_CLEANCHK (inserted after pass1)
- Tests dirty via `vm_page_test_dirty()`
- Skips cache pages and clean pages
- Calls `vm_object_page_collect_flush()` for dirty pages

**`vm_object_page_collect_flush(obj, p, pagerflags)`** (line 1148):
- Clusters adjacent dirty pages for efficient I/O
- Uses array `ma[BLIST_MAX_ALLOC]` for page cluster
- Scans backward (ib) and forward (is) from target page
- Stops at: busy pages, non-CLEANCHK, cache pages, clean pages
- Calls `vm_pageout_flush()` to write cluster

#### madvise Support

**`vm_object_madvise(obj, pindex, count, advise)`** (line 1261):
Implements madvise at object level:

| Advise | Action |
|--------|--------|
| `MADV_WILLNEED` | `vm_page_activate(m)` - move to active queue |
| `MADV_DONTNEED` | `vm_page_dontneed(m)` - deactivate/cache |
| `MADV_FREE` | Clear dirty + deactivate + free swap |

MADV_FREE restrictions:
- Only OBJT_DEFAULT or OBJT_SWAP
- Only if OBJ_ONEMAPPING set
- Clears `pmap_clear_modify()`, m->dirty, m->act_count
- Frees swap backing via `swap_pager_freespace()`

#### Page Removal

**`vm_object_page_remove(obj, start, end, clean_only)`** (line 1368):
Removes pages from object in range:

1. Sets `paging_in_progress` (PIP)
2. **Backing scan** (MGTDEVICE support):
   - Iterates `object->backing_list` under `backing_lk`
   - Calls `pmap_remove()` for each ba's address range
   - Critical for MGTDEVICE which doesn't use rb_memq
3. **RB tree scan** via `vm_object_page_remove_callback()`:
   - Loops until all pages removed (retries on busy)
4. Frees related swap (unless OBJT_SWAP && clean_only)

**`vm_object_page_remove_callback(p, data)`** (line 1508):
- Busies page, validates range
- Wired pages: just invalidate (valid=0) if !clean_only
- Clean_only mode: skips dirty pages and PG_NEED_COMMIT
- Otherwise: `vm_page_protect(VM_PROT_NONE)` + `vm_page_free()`
- Yields every 64 pages

#### Object Coalescing

**`vm_object_coalesce(prev_obj, prev_pindex, prev_size, next_size)`** (line 1601):
Extends object into adjacent virtual memory region:

- Only for OBJT_DEFAULT/OBJT_SWAP
- Fails if ref_count > 1 (unless extending size)
- Removes pages in new region if they exist
- Extends `object->size` if needed
- Returns TRUE on success

#### Dirty Flag Management

**`vm_object_set_writeable_dirty(obj)`** (line 1688):
Marks object as potentially dirty:

- Sets `OBJ_WRITEABLE | OBJ_MIGHTBEDIRTY`
- Avoids atomic op if flags already set (fast path)
- For OBJT_VNODE: sets VOBJDIRTY on vnode
  - Uses `vsetobjdirty()` for MNTK_THR_SYNC mounts (syncer list)
  - Uses `vsetflags(VOBJDIRTY)` for old-style mounts

#### DDB Debugging Commands

**`DB_SHOW_COMMAND(vmochk)`** (line 1830):
- Scans all objects in hash table
- Verifies internal objects are in some map
- Warns on zero ref_count or unmapped objects

**`DB_SHOW_COMMAND(object)`** (line 1870):
- Prints object details: type, size, resident_page_count, ref_count, flags
- With `full`: lists all pages with pindex and physical address

**`DB_SHOW_COMMAND(vmopag)`** (line 1939):
- Prints page runs for all objects
- Shows physical address contiguity

---

### Phase 4: Address Space Management

**vm_map.c** (~4,781 lines) - Address space management, vmspace lifecycle, map entries

#### 4.1 Global Data Structures and Tunables (lines 0-200)

**Allocators:**
- `vmspace_cache` - objcache for `struct vmspace` allocation
- `mapentzone` - zone allocator for `vm_map_entry` structures
- `map_entry_init[MAX_MAPENT]` - static boot-time entry pool
- Per-CPU caches: `cpu_map_entry_init_bsp[]`, `cpu_map_entry_init_ap[][]`

**Partitioning for Concurrent Faults:**
```c
#define MAP_ENTRY_PARTITION_SIZE  (32 * 1024 * 1024)  // 32MB
#define MAP_ENTRY_PARTITION_MASK  (MAP_ENTRY_PARTITION_SIZE - 1)
```
- Large anonymous mappings can be partitioned to improve concurrent fault performance
- `VM_MAP_ENTRY_WITHIN_PARTITION(entry)` - tests if entry fits in single partition

**Sysctls:**
| Sysctl | Default | Purpose |
|--------|---------|---------|
| `vm.randomize_mmap` | 0 | Randomize mmap offsets (ASLR) |
| `vm.map_relock_enable` | 1 | Insert pgtable optimization |
| `vm.map_partition_enable` | 1 | Break up large vm_map_entry's |
| `vm.map_backing_limit` | 5 | Max depth of backing_ba chain |
| `vm.map_backing_shadow_test` | 1 | Test ba.object shadow |

**MAP_BACK_* Flags:**
- `MAP_BACK_CLIPPED` (0x0001) - Entry was clipped
- `MAP_BACK_BASEOBJREFD` (0x0002) - Base object already referenced

#### 4.2 Boot Initialization (lines 207-232)

**`vm_map_startup()`** (line 207):
- Called very early in boot
- Initializes `mapentzone` with `zbootinit()`
- Uses static `map_entry_init[]` array (MAX_MAPENT entries)
- Sets `ZONE_SPECIAL` flag (required for >63 cores)

**`vm_init2()`** (line 221):
- Called before vmspace allocations
- Creates `vmspace_cache` objcache (ncpus * 4 objects)
- Calls `pmap_init2()` and `vm_object_init2()`

#### 4.3 vmspace objcache Callbacks (lines 238-258)

**`vmspace_ctor()`** (line 240):
- Zeros vmspace structure
- Sets `vm_refcnt = VM_REF_DELETED` (marks as not-in-use)

**`vmspace_dtor()`** (line 252):
- Asserts refcnt is VM_REF_DELETED
- Calls `pmap_puninit()` to cleanup pmap

#### 4.4 RB Tree for Map Entries (lines 265-277)

**`rb_vm_map_compare()`**:
- Comparison function for RB tree
- Compares `a->ba.start` vs `b->ba.start`
- Entries ordered by start address

#### 4.5 vmspace Lifecycle (lines 283-536)

**`vmspace_initrefs()`** (line 283):
- Sets `vm_refcnt = 1`, `vm_holdcnt = 1`
- Each refcnt has corresponding holdcnt

**`vmspace_alloc(min, max)`** (line 300):
1. Gets vmspace from objcache
2. Zeros `vm_startcopy` to `vm_endcopy` region
3. Calls `vm_map_init()` for embedded vm_map
4. Initializes refs (refs=1, hold=1)
5. Calls `pmap_pinit()` (some fields reused from cache)
6. Sets `vm->vm_map.pmap = vmspace_pmap(vm)`
7. Calls `cpu_vmspace_alloc()` for arch-specific init
8. Returns referenced vmspace

**`vmspace_getrefs()`** (line 336):
- Returns current refcnt (0 if exiting, -1 if deleted)

**`vmspace_hold()/vmspace_drop()`** (lines 348-372):
- `hold`: Increments holdcnt, acquires map token
- `drop`: Releases token, decrements holdcnt
- On hold 1→0 with VM_REF_DELETED: calls `vmspace_terminate(vm, 1)`

**`vmspace_ref()/vmspace_rel()`** (lines 384-421):
- `ref`: Increments holdcnt AND refcnt atomically
- `rel`: Decrements refcnt, on 1→0 sets VM_REF_DELETED and calls `vmspace_terminate(vm, 0)`
- Two-stage termination: stage-1 on refs→0, stage-2 on holds→0

**`vmspace_relexit()`** (line 434):
- Called during process exit
- Adds hold (prevents stage-2), then releases ref (triggers stage-1)

**`vmspace_exitfree()`** (line 447):
- Called during process reap
- Sets `p->p_vmspace = NULL`
- Drops hold (triggers stage-2 if last)

**`vmspace_terminate(vm, final)`** (line 470):
Two-stage termination:

**Stage 1** (final=0, refcnt reached 0):
- Sets `VMSPACE_EXIT1` flag
- Calls `shmexit()` to detach SysV shared memory
- If pmap has wired pages:
  - `vm_map_remove()` first, then `pmap_remove_pages()`
- If pmap has no wired pages (optimization):
  - `pmap_remove_pages()` first, then `vm_map_remove()`

**Stage 2** (final=1, holdcnt reached 0):
- Sets `VMSPACE_EXIT2` flag
- Calls `shmexit()` again (safety)
- Reserves map entries, locks map
- `cpu_vmspace_free()` for arch cleanup
- `vm_map_delete()` removes all remaining mappings
- `pmap_release()` releases pmap resources
- Returns vmspace to objcache

#### 4.6 vmspace Statistics (lines 546-611)

**`vmspace_swap_count()`** (line 546):
- Calculates proportional swap usage
- Iterates map entries, sums swap from backing objects
- Formula: `swblock_count * SWAP_META_PAGES * entry_pages / object_size + 1`

**`vmspace_anonymous_count()`** (line 584):
- Counts anonymous pages (OBJT_DEFAULT/OBJT_SWAP)
- Sums `object->resident_page_count` for each entry

#### 4.7 vm_map Initialization (lines 619-637)

**`vm_map_init(map, min, max, pmap)`** (line 619):
- `RB_INIT(&map->rb_root)` - entry tree
- `spin_init(&map->ilock_spin)` - interlock spinlock
- `lwkt_token_init(&map->token)` - soft serializer
- `lockinit(&map->lock)` - hard lock with 100ms timeout
- Zeros `freehint[]` array

#### 4.8 Freehint Optimization (lines 643-701)

**Purpose:** O(1) lookup for vm_map_findspace() on repeated similar requests

**`vm_map_freehint_find(map, length, align)`** (line 645):
- Searches `freehint[VM_MAP_FFCOUNT]` for matching (length, align)
- Returns cached start address or 0 if not found

**`vm_map_freehint_update(map, start, length, align)`** (line 665):
- Called after findspace succeeds
- Updates existing hint or creates new one (round-robin)
- Tracks `freehint_newindex` for replacement

**`vm_map_freehint_hole(map, start, length)`** (line 691):
- Called when hole is created (e.g., unmap)
- Updates all hints where `start < hint.start && length >= hint.length`

#### 4.9 Shadow Objects for COW (lines 703-821)

**`vm_map_entry_shadow(entry)`** (line 730):
Creates fronting object for copy-on-write:

1. Calculates length in pages
2. **Optimization**: If source object is:
   - Non-vnode type
   - ref_count == 1
   - No handle
   - OBJT_DEFAULT or OBJT_SWAP
   → Just clear NEEDS_COPY, no shadow needed

3. Otherwise creates shadow chain:
   ```
   entry->ba.object = new_result_object
   entry->ba.backing_ba = ba (contains old source object)
   entry->ba.backing_count = old_count + 1
   entry->ba.offset = 0
   ```

4. Clears `OBJ_ONEMAPPING` on source (now shared in chain)
5. Sets `pg_color = vm_quickcolor()` on result
6. Attaches both ba's to respective objects
7. Clears `MAP_ENTRY_NEEDS_COPY` flag

#### 4.10 Deferred Object Allocation (lines 823-857)

**`vm_map_entry_allocate_object(entry)`** (line 837):
- Called when anonymous mapping needs actual object
- Defers allocation until map entry split/fork/fault
- Creates OBJT_DEFAULT object sized to entry
- Sets `ba.offset = 0` for debugging clarity
- Calls `vm_map_backing_attach()` to link

#### 4.11 Per-CPU Map Entry Cache (lines 859-1011)

**Boot-time initialization:**
- `vm_map_entry_reserve_cpu_init(gd)` (line 875)
- BSP gets `MAPENTRYBSP_CACHE` (MAXCPU+1) entries
- APs get `MAPENTRYAP_CACHE` (8) entries each
- Entries linked via `gd->gd_vme_base` freelist

**`vm_map_entry_reserve(count)`** (line 908):
- Ensures `gd->gd_vme_avail >= count`
- If needed, allocates from zone in critical section
- Decrements `gd_vme_avail` by count
- Returns count (for pairing with release)

**`vm_map_entry_release(count)`** (line 943):
- Increments `gd_vme_avail`
- If `> MAP_RESERVE_SLOP`: trims back to `MAP_RESERVE_HYST`
- Frees excess back to zone

**`vm_map_entry_kreserve/krelease()`** (lines 986-1011):
- Special versions for kernel_map
- kreserve: Just decrements avail (can go negative)
- krelease: Just increments avail (no cleanup)
- Used by zalloc() to avoid recursion

**`vm_map_entry_create(countp)`** (line 1021):
- Pops entry from `gd->gd_vme_base`
- Decrements `*countp`
- Must be in critical section

#### 4.12 Backing Store Attach/Detach (lines 1041-1101)

**`vm_map_backing_attach(entry, ba)`** (line 1041):
- For NORMAL: Locks `obj->backing_lk`, inserts into `obj->backing_list`
- For UKSMAP: Calls `ba->uksmap(ba, UKSMAPOP_ADD, dev, NULL)`

**`vm_map_backing_detach(entry, ba)`** (line 1059):
- For NORMAL: Locks `obj->backing_lk`, removes from `obj->backing_list`
- For UKSMAP: Calls `ba->uksmap(ba, UKSMAPOP_REM, dev, NULL)`

**`vm_map_entry_dispose_ba(entry, ba)`** (line 1087):
- Walks backing_ba chain
- For each ba with map_object:
  - Detaches from object
  - Deallocates object reference
- Frees ba structures with kfree()

#### 4.13 Entry Dispose (lines 1103-1145)

**`vm_map_entry_dispose(map, entry, countp)`** (line 1108):
1. Disposes base object by maptype:
   - NORMAL: detach + deallocate
   - SUBMAP: nothing
   - UKSMAP: detach only
2. Disposes backing_ba chain via `vm_map_entry_dispose_ba()`
3. Clears ba fields for safety
4. Pushes entry to per-CPU freelist

#### 4.14 Entry Link/Unlink (lines 1148-1177)

**`vm_map_entry_link(map, entry)`** (line 1155):
- Increments `map->nentries`
- Inserts into RB tree, panics on duplicate

**`vm_map_entry_unlink(map, entry)`** (line 1165):
- Asserts not IN_TRANSITION
- Removes from RB tree
- Decrements `map->nentries`

#### 4.15 Entry Lookup (lines 1179-1220)

**`vm_map_lookup_entry(map, address, *entry)`** (line 1189):
- RB tree lookup for address
- Returns TRUE if address within an entry
- Sets `*entry` to containing entry or closest predecessor
- `*entry = NULL` if address before all entries

#### 4.16 Map Insert (lines 1222-1437)

**`vm_map_insert(map, countp, map_object, ...)`** (line 1233):

**Parameters:**
- `map_object`, `map_aux` - backing object/auxiliary data
- `offset` - offset into object
- `start`, `end` - address range
- `maptype` - VM_MAPTYPE_*
- `id` - vm_subsys_t identifier
- `prot`, `max` - protection
- `cow` - COWF_* flags

**Algorithm:**
1. Validate start/end against map bounds
2. Lookup `prev_entry` for start address
3. Check no overlap with next entry
4. Set `protoeflags` from COWF_* flags:
   - COWF_COPY_ON_WRITE → COW | NEEDS_COPY
   - COWF_NOFAULT → NOFAULT (object must be NULL)
   - COWF_DISABLE_SYNCER → NOSYNC
   - COWF_DISABLE_COREDUMP → NOCOREDUMP
   - COWF_IS_STACK → STACK
   - COWF_IS_KSTACK → KSTACK

5. **Coalescing optimization** (no object provided):
   If prev_entry is compatible (same eflags, id, maptype, no backing_ba):
   - Try `vm_object_coalesce()` to extend prev's object
   - If object extended AND protections match: just extend prev_entry
   - Otherwise: create new entry with ref to extended object

6. Create new `vm_map_entry`:
   - Sets ba.pmap, ba.start, ba.end, ba.offset
   - Sets id, maptype, eflags, aux
   - Inheritance = VM_INHERIT_DEFAULT
   - wired_count = 0

7. Call `vm_map_backing_replicated()` with MAP_BACK_BASEOBJREFD
8. Link entry into map
9. Update `map->size`

10. **Prefaulting** (COWF_PREFAULT):
    - Calls `pmap_object_init_pt()` to prepopulate page tables
    - Skips UKSMAP entries
    - Optional relock optimization for performance

Returns KERN_SUCCESS or error.

#### 4.17 Find Space (lines 1439-1500+)

**`vm_map_findspace(map, start, length, align, flags, *addr)`** (line 1454):
- Finds hole of `length` bytes starting at or after `start`
- `align` should be power of 2 (handled specially if not)
- `flags`: MAP_32BIT restricts to low 4GB

**Algorithm:**
1. Clamp start to map bounds
2. Compute align_mask (special value -1 if not power of 2)
3. Use freehint optimization (skip for MAP_32BIT)
4. Lookup entry at start, advance to end if within entry
5. Iterate entries looking for suitable gap...

#### 4.18 Find Space (continued, lines 1500-1580)

**`vm_map_findspace()`** Algorithm (continued):
1. Align start address to requested alignment
2. Compute end = start + length
3. Check bounds (end <= max, handle MAP_32BIT for < 4GB)
4. Find next entry, if none found → success
5. Check if gap is sufficient (special handling for STACK entries)
6. If gap insufficient, advance start to entry->ba.end, repeat

**Stack Entry Handling:**
- Stack entries reserve `avail_ssize` for growth
- MAP_TRYFIXED allows intrusion into ungrown portion
- Otherwise, gap must be >= `entry->ba.end - entry->aux.avail_ssize`

**Freehint Update:**
- On success, calls `vm_map_freehint_update(map, start, length, align)`

**Kernel Map Growth:**
- If `map == kernel_map` and `start + length > kernel_vm_end`:
- Calls `pmap_growkernel(start, kstop)` to allocate page tables
- Note: x86_64 kldload areas don't bump kernel_vm_end

#### 4.19 vm_map_find (lines 1582-1673)

**`vm_map_find(map, map_object, map_aux, offset, *addr, length, align, fitit, maptype, id, prot, max, cow)`**:

High-level wrapper combining findspace + insert:
1. Translate COWF_32BIT to MAP_32BIT flag
2. Handle UKSMAP aux_info:
   - minor 5 (/dev/upmap): aux_info = curproc
   - minor 6 (/dev/kpmap): aux_info = NULL
   - minor 7 (/dev/lpmap): aux_info = curthread->td_lwp
3. Reserve entries, lock map
4. If object: hold_shared
5. If fitit: call `vm_map_findspace()`, fail if no space
6. Call `vm_map_insert()` with found/given address
7. Drop object, unlock map, release entries
8. Return result

#### 4.20 Entry Simplification (lines 1675-1755)

**`vm_map_simplify_entry(map, entry, countp)`**:

Merges entry with adjacent neighbors if compatible:
- Skips IN_TRANSITION, SUBMAP, UKSMAP entries
- Checks compatibility:
  - Same maptype, object, backing_ba
  - Contiguous addresses and offsets
  - Same eflags, protection, max_protection, inheritance, id, wired_count

**Merge with prev:**
1. Unlink prev from RB tree
2. Adjust entry start backward via `vm_map_backing_adjust_start()`
3. Dispose prev entry

**Merge with next:**
1. Unlink next from RB tree
2. Adjust entry end forward via `vm_map_backing_adjust_end()`
3. Dispose next entry

#### 4.21 Entry Clipping (lines 1757-1885)

**`vm_map_clip_start(map, entry, startaddr, countp)`** (macro + \_vm_map_clip_start):
- Splits entry at `startaddr`, creating new entry for front portion
- Optimization: allocates object if entry has none and fits in partition
- Steps:
  1. Try simplify first
  2. Allocate object if needed (partition optimization)
  3. Create new entry, copy all fields
  4. Set new_entry->ba.end = start
  5. Replicate backing via `vm_map_backing_replicated(MAP_BACK_CLIPPED)`
  6. Adjust original entry start
  7. Link new entry

**`vm_map_clip_end(map, entry, endaddr, countp)`** (macro + \_vm_map_clip_end):
- Splits entry at `endaddr`, creating new entry for tail portion
- Similar to clip_start but creates entry after
- Adjusts new_entry->ba.start = end and offset accordingly

**`VM_MAP_RANGE_CHECK(map, start, end)`** (macro):
- Clamps start/end to map bounds

#### 4.22 Transition Wait and Clip Checking (lines 1887-1923)

**`vm_map_transition_wait(map, relock)`**:
- Blocks when IN_TRANSITION collision occurs
- Unlocks map, sleeps on map, relocks if requested

**`CLIP_CHECK_BACK(entry, save_start)`** (macro):
- Walks backward if entry was clipped during blocking operation
- Used after operations that temporarily unlock map

**`CLIP_CHECK_FWD(entry, save_end)`** (macro):
- Walks forward if entry was clipped during blocking operation

#### 4.23 Clip Range (lines 1926-2084)

**`vm_map_clip_range(map, start, end, countp, flags)`**:

Clips entries to exact range and marks IN_TRANSITION:
1. Lookup entry at start, wait if IN_TRANSITION
2. Clip start and end of first entry
3. Set IN_TRANSITION on first entry
4. Iterate through covered entries:
   - Wait if next is IN_TRANSITION
   - Clip end of each entry
   - Set IN_TRANSITION
5. If MAP_CLIP_NO_HOLES: fail if gaps detected
6. Returns start_entry

**`vm_map_unclip_range(map, start_entry, start, end, countp, flags)`**:

Undoes clip_range effects:
1. Clear IN_TRANSITION flags
2. Wake up waiters (NEEDS_WAKEUP)
3. Simplify entries to merge adjacent compatible entries

#### 4.24 Submap (lines 2086-2130)

**`vm_map_submap(map, start, end, submap)`**:
- Marks range as handled by subordinate map
- Clips to exact range
- Entry must have no COW flag and no object
- Sets `entry->ba.sub_map = submap`
- Sets `entry->maptype = VM_MAPTYPE_SUBMAP`

#### 4.25 Protection Change (lines 2132-2243)

**`vm_map_protect(map, start, end, new_prot, set_max)`**:

Changes protection on address range:

**Pass 1 - Validation:**
- Check no submaps in range
- Check `new_prot` fits within `max_protection`
- For SHARED+RW vnode mappings becoming writable: update `v_lastwrite_ts`

**Pass 2 - Apply:**
- Clip end of each entry
- If set_max: set max_protection, mask current protection
- Otherwise: set current protection
- Call `pmap_protect()` if protection changed
- COW entries mask out VM_PROT_WRITE from pmap

#### 4.26 madvise Implementation (lines 2245-2468)

**`vm_map_madvise(map, start, end, behav, value)`**:

**Map-modifying behaviors** (exclusive lock, clips entries):
| Behavior | Action |
|----------|--------|
| MADV_NORMAL | Set BEHAV_NORMAL |
| MADV_SEQUENTIAL | Set BEHAV_SEQUENTIAL |
| MADV_RANDOM | Set BEHAV_RANDOM |
| MADV_NOSYNC | Set NOSYNC flag |
| MADV_AUTOSYNC | Clear NOSYNC flag |
| MADV_NOCORE | Set NOCOREDUMP flag |
| MADV_CORE | Clear NOCOREDUMP flag |
| MADV_SETMAP | Deprecated (EINVAL) |
| MADV_INVAL | `pmap_remove()` for range |

**Object-level behaviors** (read lock, no clipping):
| Behavior | Action |
|----------|--------|
| MADV_INVAL | `vm_map_interlock()` + `pmap_remove()` |
| MADV_WILLNEED | `vm_object_madvise()` + prefault via `pmap_object_init_pt()` |
| MADV_DONTNEED | `vm_object_madvise()` |
| MADV_FREE | `vm_object_madvise()` |

#### 4.27 Inheritance Change (lines 2470-2519)

**`vm_map_inherit(map, start, end, new_inheritance)`**:
- Sets inheritance for fork behavior
- Valid values: VM_INHERIT_NONE, VM_INHERIT_COPY, VM_INHERIT_SHARE
- Clips and iterates entries, setting `entry->inheritance`

#### 4.28 User Wiring (lines 2521-2691)

**`vm_map_user_wiring(map, start, real_end, new_pageable)`**:

Implements mlock/munlock semantics:

**Wiring (new_pageable=0):**
1. Clip range with MAP_CLIP_NO_HOLES
2. For each entry:
   - Skip if already USER_WIRED
   - If wired_count > 0: just increment and set USER_WIRED
   - Otherwise: shadow if COW+WRITE, allocate object if needed
   - Increment wired_count, set USER_WIRED
   - Call `vm_fault_wire(map, entry, TRUE, 0)`
   - On failure: backout by clearing USER_WIRED and wired_count

**Unwiring (new_pageable=1):**
1. Verify all entries have USER_WIRED
2. Clear USER_WIRED, decrement wired_count
3. If wired_count becomes 0: call `vm_fault_unwire()`

#### 4.29 Kernel Wiring (lines 2693-2901)

**`vm_map_kernel_wiring(map, start, real_end, kmflags)`**:

Similar to user wiring but for kernel:

**KM_* flags:**
- `KM_KRESERVE` - Use kreserve/krelease (for zalloc recursion avoidance)
- `KM_PAGEABLE` - Unwire instead of wire

**Wiring (Pass 1):**
- Create shadow/zero-fill objects as needed
- Increment wired_count

**Wiring (Pass 2):**
- Call `vm_fault_wire()` for newly wired entries (wired_count == 1)
- On failure: backout and fall through to unwiring

**Unwiring:**
- Verify entries are wired
- Decrement wired_count
- Call `vm_fault_unwire()` when count reaches 0

#### 4.30 Quick Wiring (lines 2903-2927)

**`vm_map_set_wired_quick(map, addr, size, countp)`**:
- Marks range as wired without faulting pages
- Used when caller will load pages directly
- Sets wired_count = 1 on clipped entries

#### 4.31 Map Cleaning (lines 2929-3000+)

**`vm_map_clean(map, start, end, syncio, invalidate)`**:

Implements msync():
1. Read-lock map, verify range exists
2. Check for holes (fail if any)
3. If invalidate: `pmap_remove()` for entire range
4. For each entry:
   - Handle SUBMAP recursively
   - For NORMAL: clean object pages via `vm_object_page_clean()`
   - Handles backing_ba chain for stacked objects

*(continues in next chunk)*

#### 4.32 Map Cleaning (continued, lines 3000-3126)

**`vm_map_clean()`** (continued):
- For SUBMAP: Recursively looks up entry in submap
- For NORMAL entries with vnode object:
  - Follows backing_ba chain to find vnode object
  - Locks vnode, cleans pages via `vm_object_page_clean()`
  - If invalidate: removes pages via `vm_object_page_remove()`

#### 4.33 Entry Unwire and Delete (lines 3128-3152)

**`vm_map_entry_unwire(map, entry)`** (line 3133):
- Clears USER_WIRED flag, sets wired_count = 0
- Calls `vm_fault_unwire()` to undo wiring

**`vm_map_entry_delete(map, entry, countp)`** (line 3146):
- Unlinks entry from RB tree
- Decrements map->size
- Disposes entry via `vm_map_entry_dispose()`

#### 4.34 Map Delete (lines 3154-3332)

**`vm_map_delete(map, start, end, countp)`**:

Core deletion routine:
1. Lookup start address, clip if necessary
2. Track `hole_start` for freehint update
3. For each entry in range:
   - Wait if IN_TRANSITION
   - Clip end
   - Unwire if wired
   - Handle pmap removal + object page removal:
     - kernel_object: `pmap_remove()` + `vm_object_page_remove()`
     - vnode/device: `pmap_remove()` only (shared hold)
     - DEFAULT/SWAP with ONEMAPPING: remove pages + free swap + shrink object
     - UKSMAP: `pmap_remove()` only
   - Delete entry
4. Update freehint with new hole

**`vm_map_remove(map, start, end)`** (line 3340):
- Public wrapper for vm_map_delete()
- Handles locking and entry reservation

#### 4.35 Protection Check (lines 3356-3410)

**`vm_map_check_protection(map, start, end, protection, have_lock)`**:
- Verifies entire range has requested protection
- Checks for holes (not allowed)
- Returns TRUE if protection sufficient, FALSE otherwise

#### 4.36 Backing Replication (lines 3412-3518)

**`vm_map_backing_replicated(map, entry, flags)`** (line 3428):

Replicates vm_map_backing chain (not shared across forks):
- Walks backing_ba chain
- For each ba:
  - Sets `ba->pmap = map->pmap`
  - References object (unless base object already referenced)
  - Attaches to object's backing_list
  - If not clipped and ref_count > 1: clears OBJ_ONEMAPPING
- Allocates new ba structures for chain elements (not embedded ba)
- Adjusts offset, start, end for new addresses

**`vm_map_backing_adjust_start(entry, start)`** (line 3480):
- Adjusts start and offset for all ba's in chain
- Locks object's backing_lk during adjustment

**`vm_map_backing_adjust_end(entry, end)`** (line 3503):
- Adjusts end for all ba's in chain
- Locks object's backing_lk during adjustment

#### 4.37 Copy Entry for COW (lines 3520-3610)

**`vm_map_copy_entry(src_map, dst_map, src_entry, dst_entry)`**:

Handles COW setup for fork:

**Wired case:**
- Cannot do COW on wired pages
- Detaches dst_entry from its object
- Calls `vm_fault_copy_entry()` to copy pages physically

**Non-wired case:**
- If source not NEEDS_COPY: write-protect PTEs via `pmap_protect()`
- Set COW | NEEDS_COPY on both entries
- If no object: set dst offset to 0
- Copy PTEs via `pmap_copy()`

#### 4.38 vmspace_fork (lines 3612-3889)

**`vmspace_fork(vm1, p2, lp2)`** (line 3626):

Creates child vmspace from parent:
1. Lock old map
2. Allocate new vmspace via `vmspace_alloc()`
3. Copy vm_startcopy to vm_endcopy region (sizes, addresses)
4. Lock new map
5. Reserve entries (old_map->nentries + reserve)
6. Iterate old entries:
   - SUBMAP: panic (not allowed)
   - UKSMAP: call `vmspace_fork_uksmap_entry()`
   - NORMAL: call `vmspace_fork_normal_entry()`
7. Copy map size
8. Unlock both maps

**`vmspace_fork_normal_entry()`** (line 3688):

**Shadow chain optimization:**
- If backing_count >= vm_map_backing_limit OR object fully shadowed:
- Collapse via `vm_fault_collapse()` to reduce chain depth
- Dispose old backing_ba chain

**Fork by inheritance:**
| Inheritance | Action |
|-------------|--------|
| VM_INHERIT_NONE | Skip entry |
| VM_INHERIT_SHARE | Clone entry, share backing (ensures object allocated, does shadow if NEEDS_COPY) |
| VM_INHERIT_COPY | Clone entry, set up COW via `vm_map_copy_entry()` |

**`vmspace_fork_uksmap_entry()`** (line 3823):
- Special handling for user-kernel shared maps
- lpmap entries: only fork if TID matches lp2
- Updates aux_info to point to new proc/lwp

#### 4.39 Stack Management (lines 3891-4209)

**`vm_map_stack(map, addrbos, max_ssize, flags, prot, max, cow)`** (line 3896):

Creates auto-grow stack entry:
1. Initial size = min(max_ssize, sgrowsiz)
2. Find space for max_ssize
3. Verify no overlap with existing entries
4. Insert mapping at top of range (grows down)
5. Set `entry->aux.avail_ssize = max_ssize - init_ssize`

**`vm_map_growstack(map, addr)`** (line 4020):

Grows stack on fault:
1. Only allowed on current process
2. Find stack entry (has avail_ssize > 0)
3. Calculate grow_amount (rounded up)
4. Check against:
   - Available space (avail_ssize)
   - Previous entry gap
   - RLIMIT_STACK
   - RLIMIT_VMEM
5. Insert new mapping below stack_entry
6. Update avail_ssize and vm_ssize
7. If MAP_WIREFUTURE: wire new region

#### 4.40 vmspace_exec and vmspace_unshare (lines 4211-4275)

**`vmspace_exec(p, vmcopy)`** (line 4217):
- Unshares vmspace for exec
- If vmcopy provided: forks it (resident exec optimization)
- Otherwise: creates fresh vmspace
- Replaces process vmspace via `pmap_replacevm()`

**`vmspace_unshare(p)`** (line 4257):
- Unshares vmspace for rfork(RFMEM|RFPROC)==0
- Only forks if refcnt > 1 (actually shared)
- Forces COW

#### 4.41 Map Hint (lines 4277-4330)

**`vm_map_hint(p, addr, prot, flags)`** (line 4283):

Returns starting hint for mmap:
- If randomize_mmap=0 or addr specified:
  - Use addr if reasonable
  - Otherwise use `vm_daddr + dsiz`
- If randomize_mmap=1 and addr=0:
  - Randomize within dsiz range beyond data limit
  - Uses karc4random64() for ASLR

#### 4.42 vm_map_lookup (lines 4332-4588)

**`vm_map_lookup(var_map, vaddr, fault_type, out_entry, bap, pindex, pcount, out_prot, wflags)`**:

Core fault lookup function:
1. Reserve entries (with recursion protection via td_nest_count)
2. Lock map (read or write depending on needs)
3. Lookup entry for vaddr
4. Handle submaps: switch to submap and retry
5. Check protection:
   - OVERRIDE_WRITE uses max_protection
   - Normal uses current protection
6. Special USER_WIRED + COW + WRITE check
7. Set FW_WIRED flag if wired
8. Handle NEEDS_COPY:
   - Write fault: upgrade lock, call `vm_map_entry_shadow()`, set FW_DIDCOW
   - Read fault: mask out VM_PROT_WRITE
9. Allocate object if needed:
   - Partition large entries (> 32MB) for concurrency
   - Call `vm_map_entry_allocate_object()`
10. Return ba, pindex, pcount, prot

**`vm_map_lookup_done(map, entry, count)`** (line 4596):
- Releases read lock and entry reservation

**`vm_map_entry_partition(map, entry, vaddr, countp)`** (line 4607):
- Clips entry to 32MB partition containing vaddr

#### 4.43 Range Interlocks (lines 4617-4664)

**`vm_map_interlock(map, ilock, ran_beg, ran_end)`** (line 4620):
- Acquires interlock on address range
- Waits if overlapping interlock exists
- Used for MADV_INVAL coordination with vm_fault

**`vm_map_deinterlock(map, ilock)`** (line 4644):
- Releases interlock
- Wakes waiters if any

#### 4.44 DDB Commands (lines 4666-4781)

**`DB_SHOW_COMMAND(map, vm_map_print)`**:
- Prints map info: pmap, nentries, timestamp
- Lists all entries with protection, inheritance, wired status
- For submaps: recursively prints
- For normal: shows object, offset, COW status

**`DB_SHOW_COMMAND(procvm, procvm)`**:
- Prints process vmspace info
- Calls vm_map_print for full map dump

---

#### Key DragonFly-Specific Features (lines 0-4782)

1. **vm_map_backing chains** - Shadow objects via linked ba structures, not object chains
2. **Per-CPU entry cache** - Avoids zone allocation in hot paths
3. **Freehint optimization** - O(1) findspace for repeated similar allocations
4. **Two-stage vmspace termination** - refs→0 does bulk cleanup, holds→0 does final
5. **Entry partitioning** - 32MB partitions for concurrent anonymous faults
6. **Coalescing on insert** - Extends prev entry when possible
7. **UKSMAP callbacks** - Device-managed user-kernel shared memory

---

### Phase 5: Page Fault Handling

**vm_fault.c** (~3,243 lines) - Page fault handling, COW, prefaulting

#### 5.1 Data Structures and Tunables (lines 0-210)

**struct faultstate** (line 135):
Internal state for fault processing:
```c
struct faultstate {
    vm_page_t mary[VM_FAULT_MAX_QUICK];  /* Burst pages (max 16) */
    vm_map_backing_t ba;                  /* Current backing during iteration */
    vm_prot_t prot;                       /* Final protection for pmap */
    vm_page_t first_m;                    /* Allocated page for COW target */
    vm_map_backing_t first_ba;            /* Top-level backing */
    vm_prot_t first_prot;                 /* Protection from map lookup */
    vm_map_t map;                         /* Map being faulted */
    vm_map_entry_t entry;                 /* Entry being faulted */
    int lookup_still_valid;               /* 0=inv 1=valid/rel -1=valid/atomic */
    int hardfault;                        /* I/O required flag */
    int fault_flags;                      /* VM_FAULT_* flags */
    int shared;                           /* Using shared object lock */
    int msoftonly;                        /* Pages are soft-busied only */
    int first_shared;                     /* First object shared lock */
    int wflags;                           /* FW_* flags from lookup */
    int first_ba_held;                    /* 0=unlocked 1=locked/rel -1=lock/atomic */
    struct vnode *vp;                     /* Locked vnode for vnode pager */
};
```

**Sysctls:**
| Sysctl | Default | Description |
|--------|---------|-------------|
| `vm.debug_fault` | 0 | Debug fault output |
| `vm.debug_cluster` | 0 | Debug cluster I/O |
| `vm.shared_fault` | 1 | Allow shared object token |
| `vm.fault_bypass` | 1 | Fast lockless fault shortcut |
| `vm.prefault_pages` | 8 | Pages to prefault (half each direction) |
| `vm.fast_fault` | 1 | Burst fault zero-fill regions |

**TRYPAGER macro** (line 366):
Determines if pager might have the page:
- Object type is not OBJT_DEFAULT
- Not a wiring fault OR entry is wired

#### 5.2 Helper Functions (lines 207-283)

**release_page(fs)** (line 208):
- Deactivates and wakes fs->mary[0]

**unlock_map(fs)** (line 215):
- Drops ba->object if ba != first_ba
- Drops first_ba->object if first_ba_held == 1
- Calls vm_map_lookup_done() if lookup_still_valid == 1

**cleanup_fault(fs)** (line 242):
- Handles allocated COW page that wasn't used
- Frees first_m if not fully valid
- Resets fs->ba to first_ba

**unlock_things(fs)** (line 274):
- Calls cleanup_fault() + unlock_map()
- Puts vnode if held

#### 5.3 vm_fault() Main Entry Point (lines 387-842)

**`vm_fault(map, vaddr, fault_type, fault_flags)`** (line 387):

Main page fault handler called from trap code.

**Entry:**
1. Set LWP_PAGING flag on current lwp
2. Initialize faultstate (shared=vm_shared_fault)

**RetryFault loop:**
1. Call `vm_map_lookup()` to find entry and first_ba
   - May trigger COW shadow creation
   - May partition large entries
   - Returns first_pindex, first_count, first_prot, wflags

2. Handle lookup failures:
   - KERN_INVALID_ADDRESS + growstack: try `vm_map_growstack()`
   - KERN_PROTECTION_FAILURE + USER_WIRE: retry with OVERRIDE_WRITE

3. Special cases:
   - NOFAULT entry: panic
   - KSTACK guard page: panic
   - UKSMAP: create fake page, call uksmap callback, pmap_enter, done

4. TDF_NOFAULT check: fail if would require I/O (vnode/swap/backing)

5. **Fast path** (`vm_fault_bypass`):
   - Try lockless fault via page hash lookup
   - If successful, pages are soft-busied only
   - Skip to success path

6. **Slow path:**
   - Hold first_ba->object (shared or exclusive based on heuristics)
   - Lock vnode if needed via `vnode_pager_lock()`
   - Call `vm_fault_object()` to resolve page

7. On KERN_TRY_AGAIN: increment retry, goto RetryFault

**Success path:**
1. Set PG_REFERENCED on page
2. Call `pmap_enter()` for each page in burst
3. Handle page placement:
   - Soft-busy: drop sbusy
   - Wire: vm_page_wire() or vm_page_unwire()
   - Normal: vm_page_activate() + wakeup

4. **Prefaulting** (if VM_FAULT_BURST):
   - Exclusive locks: `vm_prefault()` (can allocate)
   - Shared locks: `vm_prefault_quick()` (existing pages only)

5. Update statistics (v_vm_faults, ru_majflt/ru_minflt)

6. **RSS limit check:**
   - If user fault and RSS > limit: `vm_pageout_map_deactivate_pages()`

#### 5.4 vm_fault_bypass() Fast Path (lines 844-980)

**`vm_fault_bypass(fs, first_pindex, first_count, mextcountp, fault_type)`**:

Lockless fault shortcut for hot pages:

**Requirements:**
- No wire operation
- Page exists in hash
- Object not dead
- Page fully valid, on PQ_ACTIVE, not PG_SWAPPED
- For writes: object OBJ_WRITEABLE|OBJ_MIGHTBEDIRTY, page fully dirty

**Algorithm:**
1. Get page via `vm_page_hash_get()` (soft-busy)
2. Validate page state
3. For writes: verify object/page already writable/dirty
4. Call `vm_page_soft_activate()` (passive queue move)
5. **Burst extension:** try to get additional consecutive pages
6. Return KERN_SUCCESS with soft-busied pages in fs->mary[]

This path avoids object locks entirely for heavily accessed pages.

#### 5.5 vm_fault_page() Variants (lines 982-1533)

**`vm_fault_page_quick(va, fault_type, errorp, busyp)`** (line 989):
- Convenience wrapper using current process vmspace

**`vm_fault_page(map, vaddr, fault_type, fault_flags, errorp, busyp)`** (line 1024):
- Returns held (and optionally busied) page without pmap update
- First tries `pmap_fault_page_quick()` for fast lookup
- Falls back to full vm_fault_object() path
- Used by vkernel, ptrace, etc.

**`vm_fault_object_page(object, offset, fault_type, fault_flags, sharedp, errorp)`** (line 1389):
- Faults page directly from object (no map)
- Creates fake vm_map_entry
- Used internally

#### 5.6 vm_fault_object() Core Logic (lines 1535-2279)

**`vm_fault_object(fs, first_pindex, fault_type, allow_nofault)`**:

Core fault resolution - walks backing chain to find/create page.

**Protection upgrade:**
- Read faults try to also enable write if mapping allows
- Downgrade for A/M bit emulation (vkernel)

**Main loop (backing chain walk):**

1. **Check object dead:** Return KERN_PROTECTION_FAILURE

2. **Lookup page:** `vm_page_lookup_busy_try()`
   - If busy: sleep, return KERN_TRY_AGAIN
   - If found and valid: break to PAGE FOUND
   - If found but PQ_CACHE and paging_severe: wait, retry
   - If found but invalid or PG_RAM: goto readrest

3. **Page not resident:**
   - If TRYPAGER or first_ba:
     - For OBJT_SWAP: check `swap_pager_haspage_locked()`
     - Require exclusive lock for allocation
     - Check pindex < object->size
     - Allocate page via `vm_page_alloc()` (skip for MGTDEVICE)
     - If allocation fails: wait, retry

4. **readrest - Page I/O:**
   - Require exclusive lock
   - Call `vm_pager_get_page()` with seqaccess hint
   - VM_PAGER_OK: hardfault++, re-lookup page, retry
   - VM_PAGER_FAIL: continue to next backing object
   - VM_PAGER_ERROR/BAD: return failure

5. **next - Continue chain:**
   - Save first_m if at first_ba
   - Get next_ba = ba->backing_ba
   - If NULL: zero-fill first_m, break
   - Hold next object, adjust pindex through offset
   - Drop current ba if not first, set ba = next_ba

**PAGE FOUND:**

6. **COW handling** (ba != first_ba):
   - Write fault: copy page from backing to first_m
     - `vm_page_copy(fs->mary[0], fs->first_m)`
     - Release backing page, drop backing object
     - Switch to first_m
   - Read fault: mask out VM_PROT_WRITE

7. **Finalization:**
   - Activate page
   - For writes: set object writeable/dirty, handle PG_SWAPPED
   - Return KERN_SUCCESS with busied page in fs->mary[0]

#### 5.7 vm_fault_wire/unwire (lines 2281-2398)

**`vm_fault_wire(map, entry, user_wire, kmflags)`** (line 2290):
- Wires range by simulating faults
- Entry must be marked IN_TRANSITION
- Unlocks map during faults
- On failure: unwinds by unwiring already-wired pages

**`vm_fault_unwire(map, entry)`** (line 2367):
- Unwires range via `pmap_unwire()` + `vm_page_unwire()`
- Skips first page for KSTACK (guard page)

#### 5.8 vm_fault_collapse (lines 2400-2471)

**`vm_fault_collapse(map, entry)`**:
- Collapses shadow chain by faulting all pages into head object
- Used during fork when backing_count >= limit
- For each pindex not in head object:
  - Call `vm_fault_object()` with WRITE+OVERRIDE
  - Activates and wakes page
- If any pages were copied: `pmap_remove()` entire range

#### 5.9 vm_fault_copy_entry (lines 2473-2559)

**`vm_fault_copy_entry(dst_map, src_map, dst_entry, src_entry)`**:
- Physically copies pages between entries (for wired COW)
- Allocates page in dst_object
- Looks up page in src_object (must exist, wired)
- `vm_page_copy()` + `pmap_enter()`
- Used when COW not possible due to wiring

#### 5.10 Prefaulting (lines 2711-3243)

**`vm_prefault(pmap, addra, entry, prot, fault_flags)`** (line 2767):

Full prefault with allocation capability (requires exclusive lock):

1. Scan ±vm_prefault_pages around fault address
2. For each address:
   - Check `pmap_prefault_ok()` - skip if already mapped
   - Walk backing chain looking for page
   - If not found and vm_fast_fault: allocate zero-fill page
   - Enter page into pmap

**`vm_prefault_quick(pmap, addra, entry, prot, fault_flags)`** (line 3061):

Lightweight prefault for shared locks:

1. Only works on terminal objects (no backing_ba)
2. For read faults: use `vm_page_lookup_sbusy_try()` (soft-busy)
3. For write faults: use `vm_page_lookup_busy_try()` (hard-busy)
4. Only maps existing valid pages, no allocation

**`vm_set_nosync(m, entry)`** (line 2756):
- Sets PG_NOSYNC if entry has NOSYNC flag and page not dirty
- Clears PG_NOSYNC if entry doesn't have NOSYNC flag

#### Key DragonFly-Specific Features

1. **vm_fault_bypass()** - Lockless fast path using page hash and soft-busy
2. **Shared object tokens** - vm_shared_fault allows concurrent read faults
3. **VM_MAP_BACK_EXCL_HEUR** - Heuristic for when to use exclusive lock
4. **Soft-busy pages** - Can map without full page lock
5. **Burst faulting** - mary[] array holds multiple pages
6. **Two-level prefaulting** - vm_prefault (full) vs vm_prefault_quick (limited)
7. **RSS enforcement** - Deactivate pages on user fault if over limit
8. **MGTDEVICE handling** - Pages not in object, directly entered in pmap

---

### Phase 6: Pageout and Swap

#### 6.1 vm_pageout.c Overview and Tunables (lines 1-300)

**Two Kernel Threads:**
- `pagedaemon` - Primary pageout daemon
- `emergpager` - Emergency pager (takes over when primary deadlocks on vnode)

**Key Global Variables:**
```c
int vm_pages_needed;          // Pageout daemon tsleep event
int vm_pageout_deficit;       // Estimated pages deficit
int vm_pageout_pages_needed;  // Pageout daemon needs pages
int vm_page_free_hysteresis = 16;
```

**Memory Thresholds (set in vm_pageout_free_page_calc()):**
- `v_free_min` - Normal allocations minimum
- `v_free_reserved` - System allocations reserve
- `v_pageout_free_min` - Pageout daemon allocation reserve  
- `v_interrupt_free_min` - Low-level allocations (swap structures)
- `v_free_target` - Target free pages (2x v_free_min)
- `v_paging_wait/start/target1/target2` - Paging thresholds (3x-5x v_free_min)

**Tunables (sysctls):**
| Sysctl | Default | Description |
|--------|---------|-------------|
| `vm.anonmem_decline` | ACT_DECLINE | Active→inactive for anon pages |
| `vm.filemem_decline` | ACT_DECLINE*2 | Active→inactive for file pages |
| `vm.max_launder` | physmem/256+16 | Max dirty pages to flush per pass |
| `vm.emerg_launder` | 100 | Emergency pager minimum |
| `vm.pageout_memuse_mode` | 2 | RSS enforcement: 0=disable, 1=passive, 2=active |
| `vm.pageout_allow_active` | 1 | Allow inactive+active scanning |
| `vm.queue_idle_perc` | 20 | Page stats stop percentage |
| `vm.swap_enabled` | 1 | Enable entire process swapout |
| `vm.defer_swapspace_pageouts` | 0 | Prefer dirty pages in mem |
| `vm.disable_swapspace_pageouts` | 0 | Disallow swap pageouts |

**Markers Structure:**
```c
struct markers {
    struct vm_page hold;  // PQ_HOLD queue marker
    struct vm_page stat;  // PQ_ACTIVE stats marker
    struct vm_page pact;  // PQ_ACTIVE paging marker
};
```

#### 6.2 Page Clustering and Flushing (lines 307-578)

**vm_pageout_clean_helper()** - Clean dirty page and adjacent pages:
- Takes a busied page, finds clusterable neighbors
- Cluster aligned to `BLIST_MAX_ALLOC` (swap optimization)
- Scans backward first for alignment, then forward
- Clusterable pages: dirty, not wired/held, inactive or allowed-active
- Sets PG_WINATCFLS flag to match primary page
- Calls `vm_pageout_flush()` for actual I/O

**vm_pageout_flush()** - Launder pages:
1. Mark all pages read-only (`vm_page_protect`)
2. Clear pmap modified bits (pager can't from interrupt context)
3. Call `vm_pager_put_pages()` for I/O
4. Handle results: VM_PAGER_OK/PEND/BAD/ERROR/FAIL/AGAIN
5. For synchronous completion, optionally try_to_cache or deactivate

**Pager Return Codes:**
- `VM_PAGER_OK` - Success, page cleaned
- `VM_PAGER_PEND` - Async I/O started
- `VM_PAGER_BAD` - Page outside object range
- `VM_PAGER_ERROR/FAIL` - Failed (e.g., out of swap)
- `VM_PAGER_AGAIN` - Retry later

#### 6.3 RSS Enforcement (lines 580-770)

**vm_pageout_mdp_callback()** - Per-page callback for RSS scan:
- Called via pmap_pgscan() for each mapped page
- Checks if RSS above limit (`pmap_resident_tlnw_count`)
- Skips wired/held/unqueued pages
- Checks pmap references (`pmap_ts_referenced`)
- Removes page from specific pmap if unreferenced
- If unmapped entirely, deactivates and optionally launders

**vm_pageout_map_deactivate_pages()** - RSS enforcement entry:
- Called when `vm_pageout_memuse_mode >= 1`
- Tracks scan position via `map->pgout_offset`
- Wraps around address space with retries
- Continues until RSS below limit

#### 6.4 Inactive Queue Scan (lines 800-1022)

**vm_pageout_scan_inactive()** - Main inactive queue scanner:
- Processes ~1/MAXSCAN_DIVIDER (1/10) of queue per pass
- Uses marker pages for position tracking
- Calculates `max_launder` per queue from `vm_max_launder`

**Emergency Pager Restrictions:**
- Skips OBJT_VNODE pages (what caused primary to deadlock)
- Only allows OBJT_DEFAULT, OBJT_SWAP
- Exception: VCHR devices without D_NOEMERGPGR flag

**Page Processing Logic:**
1. Skip markers and already-busy pages
2. Check wire_count (wired pages removed from queue)
3. Check hold_count (held pages requeued at tail)
4. Check references (pmap_ts_referenced, PG_REFERENCED)
5. If referenced: activate with boosted act_count
6. If unreferenced: proceed to clean/free

**Early Termination:**
- Stops if `vm_paging_target2()` satisfied
- Returns full completion to prevent false OOM warnings

#### 6.5 Page Decision Logic (lines 1031-1396)

**vm_pageout_page()** - Individual page handling:

Decision tree:
1. Wired → unqueue and return
2. Held → requeue at tail and return  
3. No object or ref_count==0 → clear references, continue
4. Referenced (pmap or PG_REFERENCED) → activate with ACT_ADVANCE+actcount
5. Invalid (valid==0, no NEED_COMMIT) → free directly
6. Clean (dirty==0, no NEED_COMMIT) → cache (vm_page_cache)
7. Dirty, first pass, no WINATCFLS → set flag, requeue (double-LRU)
8. Dirty, max_launder>0 → attempt pageout

**Double-LRU for Dirty Pages:**
- Dirty pages cycle twice through inactive queue before flush
- Flag `PG_WINATCFLS` ("win at cache flush") tracks first pass
- When `vm_pageout_memuse_mode >= 3`, single-LRU used instead

**Vnode Page Handling:**
- Must acquire vnode lock (vget with LK_EXCLUSIVE)
- Uses `vpfailed` to skip recently-failed vnodes  
- Handles races: page moved, freed, reused, rebusied
- If vget blocks, validates page/object/vnode still match

#### 6.6 Active Queue Scan (lines 1398-1656)

**vm_pageout_scan_active()** - Deactivate pages to feed inactive queue:
- Goal: Move pages from active to inactive
- Scans ~1/10 of queue per iteration
- Emergency pager skips vnode-backed pages

**Activity Tracking:**
- `actcount = pmap_ts_referenced(m)` + PG_REFERENCED flag
- If active references: bump act_count, leave in active queue
- If no references: decrement act_count based on object type

**Deactivation Decision:**
- `vm_anonmem_decline` for DEFAULT/SWAP objects
- `vm_filemem_decline` for file-backed (2x anon rate)
- Deactivate when: no object, ref_count==0, or act_count < pass+1
- If shortage exists: try to cache clean pages directly

#### 6.7 Cache Queue and OOM (lines 1658-1891)

**vm_pageout_scan_cache()** - Free cached pages:
- Uses two rovers (primary and emergency pager) to avoid contention
- Scans PQ_CACHE queues, frees clean pages
- Stops when v_free_target reached

**OOM Killer Logic:**
- Triggered when swap full AND still in shortage
- Rate-limited to once per second
- Scans all processes via allproc_scan()
- Selects largest process (anonymous + swap pages)
- Skips: system processes, init (pid 1), low pids with swap

**vm_pageout_scan_callback()** - OOM victim selection:
- Skips P_SYSTEM, pid==1, low pids if swap exists
- Skips non-running processes
- Size = vmspace_anonymous_count + vmspace_swap_count
- Largest wins

**Kill Action:**
- Sets P_LOWMEMKILL flag
- Calls `killproc(p, "out of swap space")`
- Wakes up memory waiters

#### 6.8 Pageout Daemon Main Loop (lines 2196-2769)

**vm_pageout_thread()** - Main daemon function:

**States:**
- `PAGING_IDLE` - No paging needed
- `PAGING_TARGET1` - Aggressive paging to target1
- `PAGING_TARGET2` - Lazy paging to target2

**Initialization (primary only):**
1. Allocate markers for all queues (PQ_L2_SIZE each)
2. Set `vm_max_launder = physmem/256 + 16`
3. Calculate thresholds from v_free_min
4. Set `v_inactive_target` = v_free_count/16
5. Initialize `swap_pager_swap_init()`
6. Sequence emergency pager startup

**Main Loop:**
```
while (TRUE) {
    1. Sleep until vm_pages_needed or timeout
    2. Calculate avail_shortage from targets
    3. Scan inactive queues (vm_pageout_scan_inactive)
    4. Calculate inactive_shortage
    5. Scan active queues (vm_pageout_scan_active)
    6. Scan cache queues (vm_pageout_scan_cache)
    7. Determine next state (IDLE/TARGET1/TARGET2)
    8. Wakeup waiters if appropriate
}
```

**Emergency Pager Differences:**
- Sleeps on `&vm_pagedaemon_uptime` not `&vm_pages_needed`
- Activates if primary hasn't updated uptime for 2+ seconds
- Only handles anonymous/swap pages (avoids vnode deadlocks)
- Iterates queues in reverse direction

#### 6.9 Supporting Functions (lines 2770-2895)

**pagedaemon_wakeup()** - Wake pageout daemon:
- Called after consuming free/cache pages
- Sets vm_pages_needed=1, wakes daemon
- Under heavy pressure, increments vm_pages_needed

**vm_req_vmdaemon()** - Request vmdaemon (RSS enforcement):
- Rate-limited to once per second
- Wakes vm_daemon_needed

**vm_daemon()** - Process scanner for RSS limits:
- Scans all processes via allproc_scan()
- Calls vm_daemon_callback() per process

**vm_daemon_callback()** - Per-process RSS check:
- Gets RLIMIT_RSS limit
- If resident > limit+4096, deactivates pages
- Uses vm_pageout_map_deactivate_pages()

#### 6.10 Key DragonFly-Specific Features (vm_pageout.c)

1. **Dual Pageout Threads:**
   - Primary for normal paging
   - Emergency pager for deadlock recovery (swap-only)

2. **Queue Distribution:**
   - PQ_L2_SIZE (1024) parallel queues per type
   - PQAVERAGE() distributes work across queues
   - Markers per queue for incremental scanning

3. **Three-State Paging:**
   - IDLE → TARGET1 (aggressive) → TARGET2 (lazy)
   - Prevents thrashing while ensuring responsiveness

4. **RSS Enforcement:**
   - `vm_pageout_memuse_mode` controls behavior
   - Mode 2: Active paging for RLIMIT_RSS
   - Mode 3: Single-LRU for dirty pages

5. **Activity Tracking:**
   - Separate decline rates for anon vs file pages
   - `vm_pageout_page_stats()` for background act_count maintenance
   - Dynamic `vm_pageout_stats_actcmp` threshold adjustment

6. **OOM Killer:**
   - Size-based victim selection
   - Rate-limited (1/sec)
   - P_LOWMEMKILL flag for identification

#### 6.11 swap_pager.c Overview and Data Structures (lines 1-300)

**Swap Pager Features (from header comments):**
- Radix bitmap (blist) for swap space management
- On-the-fly reallocation during putpages
- On-the-fly deallocation
- No garbage collection required

**Key Global Variables:**
```c
int swap_pager_full;         // Swap exhausted (triggers OOM kill)
int swap_fail_ticks;         // When exhaustion detected
int swap_pager_almost_full;  // Near exhaustion (with hysteresis)
swblk_t vm_swap_cache_use;   // Swap used for swapcache
swblk_t vm_swap_anon_use;    // Swap used for anonymous pages
struct blist *swapblist;     // Radix bitmap allocator
```

**Buffer Limits:**
- `nsw_rcount` - Read buffer limit (nswbuf_kva/2)
- `nsw_wcount_sync` - Sync write buffer limit (nswbuf_kva/4)
- `nsw_wcount_async` - Async write buffer limit (default 4)
- `nsw_cluster_max` - Max cluster size (MAXPHYS/PAGE_SIZE or MAX_PAGEOUT_CLUSTER)

**Hysteresis Thresholds:**
- `nswap_lowat` = 4% of total swap (default 128 pages)
- `nswap_hiwat` = 6% of total swap (default 512 pages)
- `swap_pager_almost_full` set when below lowat
- Cleared when above hiwat

**Swap Block Flags:**
- `SWM_FREE` (0x02) - Free the swap block
- `SWM_POP` (0x04) - Pop out (remove but don't free)

**I/O Flags:**
- `SWBIO_READ` (0x01) - Read operation
- `SWBIO_WRITE` (0x02) - Write operation
- `SWBIO_SYNC` (0x04) - Synchronous I/O
- `SWBIO_TTC` (0x08) - Try to cache after I/O

**Swap Metadata (struct swblock):**
- Stored in RB-tree per object (`object->swblock_root`)
- Each swblock covers `SWAP_META_PAGES` (16) contiguous page indices
- `swb_index` - Base page index (aligned to SWAP_META_PAGES)
- `swb_count` - Number of valid entries
- `swb_pages[SWAP_META_PAGES]` - Swap block numbers

#### 6.12 Swap Space Allocation (lines 514-800)

**swp_pager_getswapspace()** - Allocate raw swap:
- Uses blist_allocat() with iterator hint
- Falls back to start if hint fails
- Updates vm_swap_anon_use or vm_swap_cache_use
- Triggers swap_pager_full=2 on failure

**swp_pager_freeswapspace()** - Free swap blocks:
- Updates swdevt[].sw_nused
- Skips if device SW_CLOSING
- Returns blocks to blist

**swap_pager_freespace()** - Free page range metadata:
- Entry point for external callers
- Calls swp_pager_meta_free()

**swap_pager_condfree()** - Conditional free (swapcache):
- Frees whole meta-blocks with no resident pages
- Returns count of blocks freed

**swap_pager_reserve()** - Pre-allocate swap:
- Allocates swap in BLIST_MAX_ALLOC chunks
- Falls back to smaller allocations on failure
- Used for anonymous memory reservation

**swap_pager_copy()** - Copy swap metadata:
- Transfers metadata from source to destination object
- Source swapblk freed if destination has resident page
- Used during shadow chain collapse

#### 6.13 Pager Operations (lines 875-1275)

**swap_pager_haspage()** - Check for backing store:
- Looks up swblock metadata
- Returns TRUE if valid swap exists

**swap_pager_unswapped()** - Remove swap when page dirtied:
- Clears PG_SWAPPED flag
- Frees swap metadata entry

**swap_pager_strategy()** - Direct swap I/O:
- Handles BUF_CMD_READ, BUF_CMD_WRITE, BUF_CMD_FREEBLKS
- Creates I/O cluster for contiguous blocks
- Zero-fills reads with no backing store
- Uses KVABIO to avoid pmap sync

**I/O Clustering:**
- Breaks at swap device stripe boundaries (SWB_DMMASK)
- Batches contiguous operations
- Uses chain bio completion

#### 6.14 Page-In (swap_pager_getpage, lines 1300-1561)

**Burst Reading:**
- If page already valid, attempts read-ahead
- Reads up to `swap_burst_read` contiguous pages
- Sets PG_RAM on last page for pipeline continuation

**Read Process:**
1. Verify object match
2. Look up swap block for requested page
3. Scan for contiguous swap blocks (same stripe)
4. Allocate pages for burst read
5. Map pages to KVA, issue I/O
6. Wait for PBUSY_SWAPINPROG to clear
7. Return VM_PAGER_OK or VM_PAGER_ERROR

**Read-ahead Only Mode:**
- If original page valid, switches to read-ahead
- Returns immediately without waiting
- PG_RAM triggers further read-ahead on fault

#### 6.15 Page-Out (swap_pager_putpages, lines 1563-1800)

**Object Conversion:**
- Converts OBJT_DEFAULT to OBJT_SWAP on first pageout

**Synchronous Forcing:**
- Non-pageout threads forced sync unless `swap_user_async=1`
- Prevents single process hogging swap bandwidth

**Write Process:**
1. Allocate swap blocks (falls back to smaller chunks)
2. Validate stripe boundary (adjust if crossing)
3. Build swap metadata entries
4. Issue I/O (async or sync based on flags)
5. For sync: wait and call completion directly

**Async Write Limits:**
- `nsw_wcount_async_max` controlled by `swap_async_max` sysctl
- Prevents swap I/O from starving other I/O
- Default 4 concurrent async operations

#### 6.16 I/O Completion (swp_pager_async_iodone, lines 1828-2109)

**Common Processing:**
- Remove KVA mapping (pmap_qremove)
- Handle per-page based on read/write and success/error

**Read Error Handling:**
- Set m->valid = 0
- Deactivate non-requested pages
- Leave requested page busy for caller

**Write Error Handling:**
- Remove swap assignment
- Re-dirty OBJT_SWAP pages (no other backing)
- Activate page to prevent loss
- Don't dirty non-OBJT_SWAP (has vnode backing)

**Read Success:**
- Set m->valid = VM_PAGE_BITS_ALL
- Clear dirty bits
- Set PG_SWAPPED flag
- Deactivate non-requested pages

**Write Success:**
- Clear dirty bits (OBJT_SWAP only)
- Set PG_SWAPPED flag
- Deactivate if vm_paging_severe()
- Try to cache if SWBIO_TTC flag

#### 6.17 Swap Metadata Management (lines 2269-2601)

**swp_pager_lookup()** - Find swblock by index:
- Masks index to SWAP_META_MASK alignment
- RB-tree lookup on object->swblock_root

**swp_pager_meta_convert()** - Convert to swap object:
- Changes OBJT_DEFAULT to OBJT_SWAP
- Called on first swap allocation

**swp_pager_meta_build()** - Add/update swap entry:
- Creates swblock if needed (zone allocation)
- Frees any previous swap at index
- Updates swb_count and vmtotal.t_vm

**swp_pager_meta_free()** - Free range of entries:
- RB-tree scan with range comparison
- Frees swap blocks and swblock if empty
- Handles edge cases for partial swblock ranges

**swp_pager_meta_free_all()** - Destroy all metadata:
- Iterates RB-tree root
- Frees all swap blocks
- Releases all swblocks to zone

**swp_pager_meta_ctl()** - Metadata control:
- SWM_FREE: Remove and free swap
- SWM_POP: Remove but don't free (for transfer)
- Returns swap block or SWAPBLK_NONE

#### 6.18 Swapoff Support (lines 2111-2267)

**swap_pager_swapoff()** - Remove device from use:
- Scans all OBJT_SWAP/OBJT_VNODE objects
- Skips OBJ_NOPAGEIN objects
- Pages in all blocks on target device
- Returns 1 if blocks remain (partial success)

**swp_pager_fault_page()** - Fault page during swapoff:
- OBJT_VNODE: Use vm_object_page_remove()
- OBJT_SWAP: Use vm_fault_object_page()

#### 6.19 Key DragonFly-Specific Features (swap_pager.c)

1. **Radix Bitmap (blist) Allocator:**
   - Scales to arbitrary swap sizes
   - Handles fragmentation efficiently
   - O(log n) allocation/deallocation

2. **RB-Tree Swap Metadata:**
   - Per-object swap tracking
   - 16 pages per swblock entry
   - Efficient range operations

3. **Dual Swap Tracking:**
   - Separate anon vs cache accounting
   - `vm_swap_anon_use` for anonymous pages
   - `vm_swap_cache_use` for swapcache

4. **KVABIO Support:**
   - Avoids pmap synchronization overhead
   - Uses pmap_qenter_noinval() for mapping

5. **Stripe-Aware Clustering:**
   - I/O doesn't cross device stripes
   - SWB_DMMASK for boundary detection

6. **Async Throttling:**
   - Limits concurrent async writes
   - Prevents swap I/O starvation

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
