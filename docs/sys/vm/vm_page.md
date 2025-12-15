# Physical Page Management

This document describes DragonFly BSD's physical page management subsystem, implemented in `sys/vm/vm_page.c`. The subsystem manages all physical memory pages in the system, including allocation, freeing, queue management, and state transitions.

**Source file:** `sys/vm/vm_page.c` (~4,200 lines)

---

## When You Need This

| Scenario | Key Functions | Section |
|----------|---------------|---------|
| Allocating a page during fault handling | `vm_page_alloc()`, `vm_page_grab()` | [Page Allocation](#page-allocation) |
| Understanding why a page can't be freed | Wire count, hold count, busy state | [Wire/Unwire](#wireunwire), [Hold](#holdunhold), [Busy State](#busy-state-management) |
| Implementing a new pager | `vm_page_set_valid()`, `vm_page_dirty()` | [Valid/Dirty Bits](#validdirty-bit-management) |
| Debugging memory pressure issues | Page queues, vmstats | [Page Queues](#page-queues), [Memory Pressure](#memory-pressure-handling) |
| Writing DMA-capable driver code | `vm_page_alloc_contig()` | [Contiguous Allocation](#contiguous-allocation) |
| Understanding pageout victim selection | Queue transitions | [Page State Transitions](#page-state-transitions) |

---

## Overview

Every physical page in the system is represented by a `struct vm_page` (128 bytes). These structures are stored in a global array (`vm_page_array`) and indexed by physical page number. The VM system organizes pages into multiple queues based on their state and uses sophisticated coloring and NUMA-aware algorithms to optimize memory locality.

### Key Concepts

- **Page coloring**: Pages are distributed across 1024 queues per queue type to reduce lock contention and improve cache behavior
- **NUMA awareness**: Page allocation considers CPU topology to prefer local memory
- **Busy state**: Pages use atomic busy/soft-busy counts instead of traditional locks
- **Per-CPU statistics**: Reduces cache-line bouncing by caching vmstats locally

---

## Data Structures

### Page Array

```c
vm_page_t vm_page_array;           // Global array of all vm_page structures
vm_pindex_t vm_page_array_size;    // Number of entries
vm_pindex_t first_page;            // First physical page index
```

The macro `PHYS_TO_VM_PAGE(pa)` converts a physical address to its corresponding `vm_page` pointer.

### Page Queues

```c
struct vpgqueues vm_page_queues[PQ_COUNT];
```

Five queue types, each with 1024 color variants (`PQ_L2_SIZE`):

| Queue Type | Purpose |
|------------|---------|
| `PQ_FREE` | Available for allocation |
| `PQ_CACHE` | Clean pages, immediately reusable |
| `PQ_INACTIVE` | Low activity, candidates for reclamation |
| `PQ_ACTIVE` | Recently referenced pages |
| `PQ_HOLD` | Temporarily held (prevents freeing) |

Each `struct vpgqueues` contains:
- `spin` - Per-queue spinlock
- `pl` - Page list (TAILQ)
- `lcnt` - Local count
- `lastq` - Heuristic for skipping empty queues

### Page Hash Table

A lockless heuristic cache for fast page lookups:

```c
struct vm_page_hash_elm {
    vm_page_t   m;
    vm_object_t object;   // Cached for fast comparison
    vm_pindex_t pindex;   // Cached for fast comparison
    int         ticks;    // LRU timestamp
};
```

- 4-way set associative (`VM_PAGE_HASH_SET`)
- Maximum 8 million entries
- Only caches pages with `PG_MAPPEDMULTI` flag

---

## Boot-Time Initialization

### `vm_page_startup()`

Called early in boot to initialize the page management subsystem:

1. **Aligns physical memory ranges** - Rounds `phys_avail[]` to page boundaries
2. **Initializes page queues** - Creates 5120 queue structures (5 types × 1024 colors)
3. **Allocates minidump bitmap** - For crash dump support
4. **Allocates vm_page_array** - One `struct vm_page` per physical page
5. **Initializes page structures** - Sets up spinlocks and physical addresses
6. **Populates free queues** - Adds pages in ascending physical order

### Page Color Calculation

During boot, page colors are calculated with CPU locality twisting:

```c
m->pc = (pa >> PAGE_SHIFT);
m->pc ^= ((pa >> PAGE_SHIFT) / PQ_L2_SIZE);
m->pc ^= ((pa >> PAGE_SHIFT) / (PQ_L2_SIZE * PQ_L2_SIZE));
m->pc &= PQ_L2_MASK;
```

This distributes pages across queues while maintaining locality.

### NUMA Organization

`vm_numa_organize()` reorganizes page colors based on physical socket ID:

```c
socket_mod = PQ_L2_SIZE / cpu_topology_phys_ids;
socket_value = (physid % cpu_topology_phys_ids) * socket_mod;
```

`vm_numa_organize_finalize()` then balances queues to prevent empty queues that would force cross-socket borrowing.

### DMA Reserve

Low physical memory is reserved for DMA operations:

- **`vm_low_phys_reserved`**: Threshold for DMA reserve (default 65536 pages)
- **`vm_dma_reserved`**: Tunable amount to keep reserved (default 128MB on 2G+ systems)
- Pages in this range are marked `PG_FICTITIOUS | PG_UNQUEUED` and managed by `vm_contig_alist`

---

## Page Allocation

### `vm_page_alloc()`

The primary page allocation function.

```c
vm_page_t vm_page_alloc(vm_object_t object, vm_pindex_t pindex, int page_req);
```

**Allocation flags:**

| Flag | Description |
|------|-------------|
| `VM_ALLOC_NORMAL` | Can use cache pages |
| `VM_ALLOC_QUICK` | Free queue only, skip cache |
| `VM_ALLOC_SYSTEM` | Can exhaust most of free list |
| `VM_ALLOC_INTERRUPT` | Can exhaust entire free list |
| `VM_ALLOC_CPU(n)` | CPU localization hint |
| `VM_ALLOC_ZERO` | Zero page if allocated |
| `VM_ALLOC_NULL_OK` | Return NULL on collision |

**Algorithm:**

1. Calculate page color via `vm_get_pg_color(cpuid, object, pindex)`
2. Check free count against thresholds
3. Search free queue (and optionally cache queue)
4. If using cache page, free it first then retry
5. Insert into object if provided
6. Return BUSY page

### CPU-Localized Color Selection

`vm_get_pg_color()` calculates colors considering CPU topology:

```c
// General format: [phys_id][core_id][cpuid][set-associativity]
physcale = PQ_L2_SIZE / cpu_topology_phys_ids;
grpscale = physcale / cpu_topology_core_ids;
cpuscale = grpscale / cpu_topology_ht_ids;

pg_color = phys_id * physcale;
pg_color += core_id * grpscale;
pg_color += ht_id * cpuscale;
pg_color += (pindex + object_pg_color) % cpuscale;
```

### Queue Search Algorithm

`_vm_page_list_find()` searches for pages with widening locality:

1. Try exact color queue first
2. Widen search: 16 → 32 → 64 → 128 → ... → 1024 queues
3. Track `lastq` to skip known-empty queues
4. Return spinlocked page removed from queue

### Contiguous Allocation

For DMA and device drivers requiring physically contiguous memory:

```c
vm_page_t vm_page_alloc_contig(vm_paddr_t low, vm_paddr_t high,
                               unsigned long alignment,
                               unsigned long boundary,
                               unsigned long size,
                               vm_memattr_t memattr);
```

Uses the `vm_contig_alist` allocator for low-memory DMA pages.

### Other Allocation Functions

| Function | Description |
|----------|-------------|
| `vm_page_alloczwq()` | Allocate without object, returns wired page |
| `vm_page_grab()` | Lookup-or-allocate with object |

---

## Page Freeing

### `vm_page_free_toq()`

The main page freeing function:

1. Assert page not mapped (calls `pmap_mapped_sync()` if needed)
2. Remove from object via `vm_page_remove()`
3. For fictitious pages: just wakeup and return
4. Remove from current queue
5. Clear valid/dirty bits
6. Place on appropriate queue:
   - `PQ_HOLD` if `hold_count != 0`
   - `PQ_FREE` otherwise (at head for cache-hot)
7. Wake up page waiters
8. Wake memory-waiting threads via `vm_page_free_wakeup()`

### Free Wakeup Logic

`vm_page_free_wakeup()` signals:
- **Pageout daemon**: If it needs pages and threshold met
- **Memory-waiting processes**: If above hysteresis threshold

---

## Page State Transitions

```
                    ┌─────────────┐
                    │   PQ_FREE   │
                    └──────┬──────┘
                           │ alloc
                           ▼
              ┌────────────────────────┐
              │       PQ_ACTIVE        │
              └────────────┬───────────┘
                           │ deactivate
                           ▼
              ┌────────────────────────┐
              │      PQ_INACTIVE       │
              └────────────┬───────────┘
                           │ clean
                           ▼
              ┌────────────────────────┐
              │       PQ_CACHE         │◄──── clean, not mapped
              └────────────┬───────────┘
                           │ free
                           ▼
              ┌────────────────────────┐
              │   PQ_FREE or PQ_HOLD   │
              └────────────────────────┘
```

### Activation

`vm_page_activate()` moves a page to `PQ_ACTIVE`:
- Sets `act_count` to at least `ACT_INIT`
- Wakes pagedaemon if page was on cache/free queue

### Deactivation

`vm_page_deactivate()` moves a page to `PQ_INACTIVE`:
- Clears `PG_WINATCFLS` flag
- Optional `athead` for pseudo-cache behavior (MADV_DONTNEED)

### Caching

`vm_page_cache()` moves a clean page to `PQ_CACHE`:
- Removes all pmap mappings first
- Dirty pages are deactivated instead

---

## Busy State Management

DragonFly uses atomic busy counts instead of traditional locks.

### Hard Busy (`PBUSY_LOCKED`)

Exclusive access to the page.

```c
void vm_page_busy_wait(vm_page_t m, int also_m_busy, const char *msg);
int  vm_page_busy_try(vm_page_t m, int also_m_busy);
void vm_page_wakeup(vm_page_t m);
```

- `vm_page_busy_wait()`: Blocks until page not busy
- `vm_page_busy_try()`: Non-blocking attempt, returns TRUE on failure
- `vm_page_wakeup()`: Clears busy and wakes waiters

### Soft Busy (`PBUSY_MASK`)

Shared access for compatible operations (e.g., read-only mapping during write).

```c
void vm_page_io_start(vm_page_t m);   // Increment soft-busy (requires hard-busy)
void vm_page_io_finish(vm_page_t m);  // Decrement soft-busy
int  vm_page_sbusy_try(vm_page_t m);  // Non-blocking soft-busy acquire
```

### Waiting

`vm_page_sleep_busy()` sleeps until page not busy without acquiring it.

---

## Wire/Unwire

Wiring prevents a page from being paged out.

```c
void vm_page_wire(vm_page_t m);
void vm_page_unwire(vm_page_t m, int activate);
```

- `vm_page_wire()`: Increments `wire_count`, adjusts vmstats on 0→1
- `vm_page_unwire()`: Decrements `wire_count`, activates or deactivates on 1→0
- Fictitious pages ignore wire operations

---

## Hold/Unhold

Holding prevents page reuse but not disassociation from object.

```c
void vm_page_hold(vm_page_t m);
void vm_page_unhold(vm_page_t m);
```

On last unhold, if page is on `PQ_HOLD`, it moves to `PQ_FREE`.

---

## Page Lookup

### Standard Lookup

```c
vm_page_t vm_page_lookup(vm_object_t object, vm_pindex_t pindex);
```

Requires object token held. Does RB-tree lookup and populates hash cache.

### Lookup + Busy

```c
// Blocking
vm_page_t vm_page_lookup_busy_wait(vm_object_t object, vm_pindex_t pindex,
                                   int also_m_busy, const char *msg);

// Non-blocking
vm_page_t vm_page_lookup_busy_try(vm_object_t object, vm_pindex_t pindex,
                                  int also_m_busy, int *errorp);
```

### Fast Heuristic Lookup

```c
vm_page_t vm_page_hash_get(vm_object_t object, vm_pindex_t pindex);
```

Lockless lookup returning soft-busied page on hit.

---

## Valid/Dirty Bit Management

Each page has 8 valid and 8 dirty bits (one per DEV_BSIZE chunk, typically 512 bytes).

### Functions

| Function | Description |
|----------|-------------|
| `vm_page_bits(base, size)` | Convert range to bit mask |
| `vm_page_set_valid()` | Set valid bits, zero invalid portions |
| `vm_page_set_validclean()` | Set valid, clear dirty |
| `vm_page_set_validdirty()` | Set both valid and dirty |
| `vm_page_clear_dirty()` | Clear dirty bits |
| `vm_page_dirty()` | Set all dirty bits |
| `vm_page_test_dirty()` | Sync dirty from pmap |
| `vm_page_zero_invalid()` | Zero invalid portions before mapping |
| `vm_page_is_valid()` | Check if range is valid |

---

## Memory Pressure Handling

### Waiting Functions

| Function | Description |
|----------|-------------|
| `vm_wait()` | Block until memory available (I/O path) |
| `vm_wait_pfault()` | Block in page fault path (nice-aware) |
| `vm_wait_nominal()` | Block for kernel heavy operations |
| `vm_test_nominal()` | Test if vm_wait_nominal would block |

### Nice-Aware Paging

Process nice value affects paging thresholds:
- Higher nice = earlier blocking
- Prevents nice'd memory hogs from impacting normal processes

### Low Memory Kill

Processes with `P_LOWMEMKILL` flag can break out of wait loops.

---

## madvise Support

### `vm_page_dontneed()`

Implements `MADV_DONTNEED`:
- 3/32 chance: deactivate page
- 28/32 chance: deactivate at head (pseudo-cache)
- Clears `PG_REFERENCED`

---

## Special Page Types

### Fictitious Pages

Pages with `PG_FICTITIOUS` flag:
- Not in normal page array
- Created via `vm_page_initfake()`
- Wire/unwire operations ignored
- Used for device mappings (GPU, etc.)

### Pages Requiring Commit

Pages with `PG_NEED_COMMIT` flag:
- Cannot be reclaimed even if clean
- Used by tmpfs, NFS
- Set via `vm_page_need_commit()`

---

## Locking Rules

### Queue Operations

Locking order: **Page spinlock first, then queue spinlock**

```c
vm_page_spin_lock(m);           // Lock page
_vm_page_queue_spin_lock(m);    // Then lock its queue
// ... manipulate queue ...
_vm_page_queue_spin_unlock(m);  // Unlock queue first
vm_page_spin_unlock(m);         // Then unlock page
```

### Per-CPU Statistics

Queue adjustments update per-CPU vmstats:
- `mycpu->gd_vmstats_adj` - Accumulated adjustments
- `mycpu->gd_vmstats` - Current view
- Synchronized to global `vmstats` periodically or when threshold exceeded

---

## Debugging

### DDB Commands

| Command | Description |
|---------|-------------|
| `show page` | Display vmstats counters |
| `show pageq` | Display queue lengths per color |

### Sysctls

| Sysctl | Description |
|--------|-------------|
| `vm.dma_reserved` | Memory reserved for DMA |
| `vm.dma_free_pages` | Available DMA pages |
| `vm.page_hash_vnode_only` | Only hash vnode pages |

---

## DragonFly-Specific Features

1. **1024-color page queues** - Extreme SMP scalability
2. **NUMA-aware coloring** - Automatic per-socket page distribution
3. **Per-CPU vmstats caching** - Reduces cache-line bouncing
4. **Heuristic page hash** - Lockless fast path for lookups
5. **Nice-aware paging** - Fair memory allocation under pressure
6. **DMA alist reserve** - Efficient contiguous allocation

---

## See Also

- [VM Architecture Overview](index.md)
- `sys/vm/vm_page.h` - Page structure and flags
- `sys/vm/vm_page2.h` - Inline functions and thresholds
