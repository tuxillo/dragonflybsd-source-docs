# Page Fault Handling

The page fault handler resolves virtual memory faults by locating or creating physical pages and establishing pmap mappings. DragonFly BSD's implementation emphasizes SMP scalability through shared locking, lockless fast paths, and burst faulting.

**Source file:** `sys/vm/vm_fault.c` (~3,243 lines)

## When This Code Runs

Page faults are **triggered by hardware** when a process accesses memory that:

| Trigger | Cause | Typical Resolution |
|---------|-------|-------------------|
| First access after mmap() | No PTE exists | Allocate page, zero-fill or load from file |
| Exec touches new code page | Demand paging | Load from executable via vnode_pager |
| Write to COW page after fork() | PTE is read-only | Copy page, update PTE to writable |
| Stack growth | Access below current stack | Expand stack via `vm_map_growstack()` |
| Swapped-out page access | Page not resident | Load from swap via swap_pager |
| MADV_DONTNEED region access | Page was freed | Zero-fill new page |

## High-Level Flow

```
HARDWARE TRAP
     │
     v
┌─────────────────────────────────────────────────────────────┐
│ trap() → vm_fault(map, vaddr, fault_type, fault_flags)      │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          v
┌─────────────────────────────────────────────────────────────┐
│ 1. vm_map_lookup()                                          │
│    - Find vm_map_entry for faulting address                 │
│    - Handle COW setup (shadow object creation)              │
│    - Return backing chain and protection                    │
└─────────────────────────┬───────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          │                               │
          v                               v
┌───────────────────────┐     ┌───────────────────────┐
│ 2a. vm_fault_bypass() │     │ 2b. vm_fault_object() │
│   (FAST PATH)         │     │   (SLOW PATH)         │
│                       │     │                       │
│ - Page in hash cache  │     │ - Walk backing chain  │
│ - Already valid/dirty │     │ - Call pager if needed│
│ - No locks needed     │     │ - Handle COW copy     │
│ - Soft-busy only      │     │ - Zero-fill if new    │
└───────────┬───────────┘     └───────────┬───────────┘
            │                             │
            └──────────────┬──────────────┘
                           │
                           v
┌─────────────────────────────────────────────────────────────┐
│ 3. pmap_enter() - Install PTE for virtual→physical mapping  │
└─────────────────────────────────────────────────────────────┘
```

---

## Overview

When a process accesses unmapped or protected memory, the hardware generates a page fault. The fault handler must:

1. Find the vm_map_entry for the faulting address
2. Walk the vm_map_backing chain to locate the page
3. Handle copy-on-write if needed
4. Page in from backing store (file/swap) if needed
5. Enter the page into the pmap

DragonFly optimizes this path with:
- **Lockless bypass** for frequently accessed pages
- **Shared object tokens** for concurrent read faults
- **Burst faulting** to map multiple pages at once
- **Two-level prefaulting** based on lock mode

## Data Structures

### struct faultstate

Internal state maintained during fault processing:

```c
struct faultstate {
    vm_page_t mary[VM_FAULT_MAX_QUICK];  /* Burst pages (max 16) */
    vm_map_backing_t ba;            /* Current backing during iteration */
    vm_prot_t prot;                 /* Final protection for pmap */
    vm_page_t first_m;              /* Allocated page for COW target */
    vm_map_backing_t first_ba;      /* Top-level backing */
    vm_prot_t first_prot;           /* Protection from map lookup */
    vm_map_t map;                   /* Map being faulted */
    vm_map_entry_t entry;           /* Entry being faulted */
    int lookup_still_valid;         /* Map lock state */
    int hardfault;                  /* I/O was required */
    int fault_flags;                /* VM_FAULT_* flags */
    int shared;                     /* Using shared object lock */
    int msoftonly;                  /* Pages are soft-busied only */
    int first_shared;               /* First object has shared lock */
    int wflags;                     /* FW_* flags from lookup */
    int first_ba_held;              /* Object lock state */
    struct vnode *vp;               /* Locked vnode (if any) */
};
```

### Fault Flags

| Flag | Description |
|------|-------------|
| `VM_FAULT_NORMAL` | Standard fault |
| `VM_FAULT_WIRE_MASK` | Wiring operation |
| `VM_FAULT_USER_WIRE` | User wiring (mlock) |
| `VM_FAULT_CHANGE_WIRING` | Kernel wiring |
| `VM_FAULT_BURST` | Enable prefaulting |
| `VM_FAULT_DIRTY` | Mark page dirty |
| `VM_FAULT_UNSWAP` | Remove swap backing |
| `VM_FAULT_USERMODE` | User-mode fault |

### Wiring Flags (wflags)

| Flag | Description |
|------|-------------|
| `FW_WIRED` | Entry is wired |
| `FW_DIDCOW` | COW was performed |

## Main Entry Point

```c
int vm_fault(vm_map_t map, vm_offset_t vaddr, 
             vm_prot_t fault_type, int fault_flags);
```

Called from the trap handler when a page fault occurs.

### Algorithm

**1. Initialization:**
- Set `LWP_PAGING` flag on current LWP
- Initialize faultstate with shared lock preference

**2. Map Lookup (RetryFault):**
```c
result = vm_map_lookup(&fs.map, vaddr, fault_type,
                       &fs.entry, &fs.first_ba,
                       &first_pindex, &first_count,
                       &fs.first_prot, &fs.wflags);
```

The lookup may:
- Create a shadow object for COW
- Partition large entries for concurrency
- Return protection and wiring state

**3. Handle Lookup Failures:**
- `KERN_INVALID_ADDRESS`: Try `vm_map_growstack()` for stack faults
- `KERN_PROTECTION_FAILURE` with USER_WIRE: Retry with `VM_PROT_OVERRIDE_WRITE`

**4. Special Entry Types:**
- `MAP_ENTRY_NOFAULT`: Panic (should never fault)
- `MAP_ENTRY_KSTACK` guard page: Panic
- `VM_MAPTYPE_UKSMAP`: Call device callback, map directly

**5. Fast Path (vm_fault_bypass):**
```c
if (vm_fault_bypass_count &&
    vm_fault_bypass(&fs, first_pindex, first_count,
                   &mextcount, fault_type) == KERN_SUCCESS) {
    goto success;
}
```

**6. Slow Path:**
- Acquire object lock (shared or exclusive)
- Lock vnode if needed
- Call `vm_fault_object()` to resolve page

**7. Success:**
- Set `PG_REFERENCED` on page
- Enter page(s) into pmap
- Handle wiring or activate page
- Prefault nearby pages if `VM_FAULT_BURST`

**8. Statistics:**
- Increment `v_vm_faults`
- Update `ru_majflt` (hard) or `ru_minflt` (soft)
- Check RSS limits, deactivate pages if exceeded

## Lockless Fast Path

```c
static int vm_fault_bypass(struct faultstate *fs, vm_pindex_t first_pindex,
                           vm_pindex_t first_count, int *mextcountp,
                           vm_prot_t fault_type);
```

Attempts to resolve the fault without acquiring object locks:

### Requirements

- No wiring operation in progress
- Page exists in object's page hash
- Object is not dead
- Page is fully valid, on `PQ_ACTIVE`, not `PG_SWAPPED`
- For writes: object and page already marked writable/dirty

### Algorithm

1. Look up page via `vm_page_hash_get()` (acquires soft-busy)
2. Validate page state
3. For writes: verify `OBJ_WRITEABLE | OBJ_MIGHTBEDIRTY` and `dirty == VM_PAGE_BITS_ALL`
4. Call `vm_page_soft_activate()` (passive queue manipulation)
5. Optionally burst: get additional consecutive pages
6. Return with soft-busied pages in `fs->mary[]`

### Benefits

- No object token acquisition
- No hard page busy
- Excellent for shared executables and libraries
- Multiple pages can be mapped in single operation

## Core Fault Logic

```c
static int vm_fault_object(struct faultstate *fs, vm_pindex_t first_pindex,
                           vm_prot_t fault_type, int allow_nofault);
```

Walks the backing chain to find or create the target page.

### Protection Upgrade

For read faults, the code attempts to also enable write access if:
- The mapping allows writes
- The page is not COW
- The pmap doesn't require A/M bit emulation (vkernel)

### Main Loop (Backing Chain Walk)

```
for (;;) {
    1. Check if object is dead
    2. Look up page in current object
    3. If found and valid → break to PAGE FOUND
    4. If not found → try pager or allocate
    5. Move to next backing object
}
```

**Page Lookup:**
```c
fs->mary[0] = vm_page_lookup_busy_try(fs->ba->object, pindex, TRUE, &error);
```

If the page is busy, sleep and return `KERN_TRY_AGAIN`.

**Page Not Resident:**

For `OBJT_SWAP` objects, check `swap_pager_haspage_locked()` before allocating.

If the page might be in the pager (`TRYPAGER`) or this is the first object:
1. Require exclusive lock for allocation
2. Check `pindex < object->size`
3. Allocate via `vm_page_alloc()`

**Pager I/O:**
```c
rv = vm_pager_get_page(object, pindex, &fs->mary[0], seqaccess);
```

| Result | Action |
|--------|--------|
| `VM_PAGER_OK` | Increment hardfault, re-lookup page |
| `VM_PAGER_FAIL` | Continue to next backing object |
| `VM_PAGER_ERROR` | Return `KERN_FAILURE` |
| `VM_PAGER_BAD` | Return `KERN_PROTECTION_FAILURE` |

**Continue to Next Object:**
```c
next_ba = fs->ba->backing_ba;
if (next_ba == NULL) {
    /* Zero-fill the page */
    vm_page_zero_fill(fs->mary[0]);
    break;
}
/* Adjust pindex through offset chain */
pindex -= OFF_TO_IDX(fs->ba->offset);
pindex += OFF_TO_IDX(next_ba->offset);
fs->ba = next_ba;
```

### Copy-On-Write

When the page is found in a backing object (`ba != first_ba`) and this is a write fault:

```c
/* Copy from backing page to first_m */
vm_page_copy(fs->mary[0], fs->first_m);

/* Release backing page and object */
release_page(fs);
vm_object_pip_wakeup(fs->ba->object);
vm_object_drop(fs->ba->object);

/* Switch to the copy */
fs->ba = fs->first_ba;
fs->mary[0] = fs->first_m;
```

For read faults on backing pages, write permission is masked:
```c
fs->prot &= ~VM_PROT_WRITE;
```

### Finalization

1. Activate the page
2. For writes:
   - `vm_object_set_writeable_dirty()`
   - Handle `PG_SWAPPED` (requires exclusive lock for `swap_pager_unswapped()`)
3. Return `KERN_SUCCESS` with busied page

## Wiring Support

### vm_fault_wire

```c
int vm_fault_wire(vm_map_t map, vm_map_entry_t entry,
                  boolean_t user_wire, int kmflags);
```

Wires a range by simulating faults:

1. Entry must be marked `IN_TRANSITION`
2. Unlock map during faults
3. For each page: call `vm_fault()` with wire flags
4. On failure: unwire already-wired pages

### vm_fault_unwire

```c
void vm_fault_unwire(vm_map_t map, vm_map_entry_t entry);
```

Unwires a range:
- Calls `pmap_unwire()` to get page
- Calls `vm_page_unwire()` to decrement wire count
- Skips guard page for `MAP_ENTRY_KSTACK`

## Shadow Collapse

```c
int vm_fault_collapse(vm_map_t map, vm_map_entry_t entry);
```

Used during fork when the backing chain exceeds `vm.map_backing_limit`:

1. For each pindex in entry range:
   - Skip if page already in head object
   - Call `vm_fault_object()` with write permission
   - Activates and wakes page
2. If any pages copied: `pmap_remove()` entire range

This brings all pages into the head object, allowing the backing chain to be freed.

## Physical Page Copy

```c
void vm_fault_copy_entry(vm_map_t dst_map, vm_map_t src_map,
                         vm_map_entry_t dst_entry, vm_map_entry_t src_entry);
```

Physically copies pages between entries when COW is not possible (wired pages):

1. Allocate destination object
2. For each page:
   - Allocate page in destination
   - Look up page in source (must exist)
   - `vm_page_copy()` contents
   - `pmap_enter()` into destination pmap

## Prefaulting

Prefaulting maps nearby pages after a fault to reduce future faults.

### Full Prefault

```c
static void vm_prefault(pmap_t pmap, vm_offset_t addra,
                        vm_map_entry_t entry, int prot, int fault_flags);
```

Used when holding exclusive object lock:

1. Scan ±`vm_prefault_pages` (default 8) around fault address
2. Skip already-mapped pages (`pmap_prefault_ok()`)
3. Walk backing chain for each address
4. If not found and `vm_fast_fault`: allocate zero-fill page
5. Enter page into pmap

### Quick Prefault

```c
static void vm_prefault_quick(pmap_t pmap, vm_offset_t addra,
                              vm_map_entry_t entry, int prot, int fault_flags);
```

Used when holding shared object lock:

- Only works on terminal objects (no backing chain)
- Uses `vm_page_lookup_sbusy_try()` for soft-busy
- Only maps existing valid pages, no allocation
- Much lower overhead than full prefault

### Selection

```c
if (fs.first_shared == 0 && fs.shared == 0) {
    vm_prefault(pmap, vaddr, entry, prot, fault_flags);
} else {
    vm_prefault_quick(pmap, vaddr, entry, prot, fault_flags);
}
```

## Alternative Entry Points

### vm_fault_page

```c
vm_page_t vm_fault_page(vm_map_t map, vm_offset_t vaddr, vm_prot_t fault_type,
                        int fault_flags, int *errorp, int *busyp);
```

Returns a held (and optionally busied) page without pmap update:

1. First tries `pmap_fault_page_quick()` for fast lookup
2. Falls back to full `vm_fault_object()` path
3. Returns held page, optionally busied for writes
4. Used by vkernel, ptrace, and similar

### vm_fault_page_quick

```c
vm_page_t vm_fault_page_quick(vm_offset_t va, vm_prot_t fault_type,
                              int *errorp, int *busyp);
```

Convenience wrapper using current process vmspace.

### vm_fault_object_page

```c
vm_page_t vm_fault_object_page(vm_object_t object, vm_ooffset_t offset,
                               vm_prot_t fault_type, int fault_flags,
                               int *sharedp, int *errorp);
```

Faults a page directly from an object (no map involvement):
- Creates fake `vm_map_entry`
- Used internally for direct object access

## Sysctls

| Sysctl | Default | Description |
|--------|---------|-------------|
| `vm.shared_fault` | 1 | Allow shared object token for faults |
| `vm.fault_bypass` | 1 | Enable lockless fast path |
| `vm.prefault_pages` | 8 | Pages to prefault each direction |
| `vm.fast_fault` | 1 | Allow zero-fill allocation during prefault |
| `vm.debug_fault` | 0 | Debug output for faults |
| `vm.debug_cluster` | 0 | Debug output for I/O clustering |

## DragonFly-Specific Features

### Lockless Bypass

`vm_fault_bypass()` uses the page hash table to find pages without acquiring object locks. Pages are soft-busied only, allowing concurrent access. This dramatically improves performance for shared libraries and executables.

### Shared Object Tokens

The `vm_shared_fault` sysctl (default on) allows read faults to use shared object tokens. This enables concurrent faults on the same object from different processes, important for fork-heavy workloads.

### Exclusive Lock Heuristics

`VM_MAP_BACK_EXCL_HEUR` tracks when exclusive locks were needed, avoiding unnecessary shared→exclusive upgrades on subsequent faults.

### Burst Faulting

The `mary[]` array (max 16 pages) allows multiple pages to be faulted in a single operation. Combined with prefaulting, this reduces per-page overhead.

### RSS Enforcement

After user faults, the code checks process RSS against `RLIMIT_RSS`:
```c
if (size > limit) {
    vm_pageout_map_deactivate_pages(map, limit);
}
```

### MGTDEVICE Support

For managed device objects (GPU/DRM), pages are not indexed in the VM object. The pager returns pages directly for pmap entry without object insertion.

## See Also

- [VM Subsystem Overview](index.md) - Architecture overview
- [Physical Pages](vm_page.md) - Page allocation and states
- [VM Objects](vm_object.md) - Object lifecycle
- [Address Space](vm_map.md) - Map lookup and entry management
