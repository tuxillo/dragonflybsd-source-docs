# Memory Mapping and Pagers

The memory mapping subsystem provides the mmap() interface for applications to map files and anonymous memory into their address space. The vnode pager handles file-backed I/O for memory-mapped files.

**Source files:** `sys/vm/vm_mmap.c` (~1,530 lines), `sys/vm/vnode_pager.c` (~832 lines)

## Overview

Memory mapping connects user address space to backing store:

```
User Address Space          VM Layer              Backing Store
─────────────────           ────────              ─────────────
                            
┌─────────────┐       ┌──────────────┐       ┌─────────────┐
│  mmap()     │ ────→ │  vm_map_find │ ────→ │  Anonymous  │
│  MAP_ANON   │       │  vm_object   │       │  (swap)     │
└─────────────┘       └──────────────┘       └─────────────┘

┌─────────────┐       ┌──────────────┐       ┌─────────────┐
│  mmap()     │ ────→ │  vm_map_find │ ────→ │ vnode_pager │
│  file fd    │       │  vm_object   │       │  (file)     │
└─────────────┘       └──────────────┘       └─────────────┘

┌─────────────┐       ┌──────────────┐       ┌─────────────┐
│  mmap()     │ ────→ │  vm_map_find │ ────→ │  dev_pager  │
│  device     │       │  vm_object   │       │  (device)   │
└─────────────┘       └──────────────┘       └─────────────┘
```

## Vnode Pager (vnode_pager.c)

The vnode pager provides VM object backing for regular files, allowing memory-mapped file I/O.

### Pager Operations

```c
struct pagerops vnodepagerops = {
    .pgo_dealloc  = vnode_pager_dealloc,
    .pgo_getpage  = vnode_pager_getpage,
    .pgo_putpages = vnode_pager_putpages,
    .pgo_haspage  = vnode_pager_haspage
};
```

| Operation | Description |
|-----------|-------------|
| `dealloc` | Clean up when object destroyed |
| `getpage` | Page in from file |
| `putpages` | Page out to file |
| `haspage` | Check if file has backing for page |

### Object Allocation

**`vnode_pager_alloc(handle, length, prot, offset, blksize, boff)`**

Creates or references a VM object for a vnode:

1. Acquire vnode token for serialization
2. If object exists: reference it, validate size
3. If no object: create new `OBJT_VNODE` object
4. Set `vp->v_object`, `vp->v_filesize`
5. If mount has `MNTK_NOMSYNC`: set `OBJ_NOMSYNC`
6. Take vnode reference

**Object sizing:**
```c
/* Round up to next block, then to page boundary */
if (boff < 0)
    boff = (int)(length % blksize);
if (boff)
    loffset = length + (blksize - boff);
else
    loffset = length;
lsize = OFF_TO_IDX(round_page64(loffset));
```

The object size includes any partial buffer cache block straddling EOF.

**`vnode_pager_reference(vp)`**

Adds a reference to an existing vnode's VM object without creating a new one. Returns NULL if no object exists.

### Page-In (vnode_pager_getpage)

**`vnode_pager_getpage(object, pindex, mpp, seqaccess)`**

Wrapper that calls `VOP_GETPAGES()` on the vnode.

**`vnode_pager_generic_getpages(vp, mpp, bytecount, reqpage, seqaccess)`**

Generic implementation for filesystems that don't implement `VOP_GETPAGES`:

1. Validate vnode mount state
2. Discard pages past file EOF
3. For block/char devices: round up to sector size
4. Release page busy state temporarily (deadlock avoidance)
5. Issue `VOP_READ()` with `IO_VMIO` flag
6. Re-acquire page busy state
7. Handle results per page:
   - Non-requested pages: activate if referenced, else deactivate
   - Requested page: validate, zero-fill partial pages

**I/O flags:**
```c
ioflags = IO_VMIO;
if (seqaccess)
    ioflags |= IO_SEQMAX << IO_SEQSHIFT;
```

### Page-Out (vnode_pager_putpages)

**`vnode_pager_putpages(object, m, count, flags, rtvals)`**

Wrapper that calls `VOP_PUTPAGES()` on the vnode.

**Low memory handling:**
```c
if ((vmstats.v_free_count + vmstats.v_cache_count) <
    vmstats.v_pageout_free_min) {
    flags |= OBJPC_SYNC;  /* Force synchronous */
}
```

**`vnode_pager_generic_putpages(vp, m, bytecount, flags, rtvals)`**

Generic implementation:

1. Truncate write to file EOF
2. Set I/O flags based on `OBJPC_*` flags
3. Issue `VOP_WRITE()` with `IO_VMIO`
4. Mark pages clean on success

**I/O clustering:**
```c
ioflags = IO_VMIO;
if (flags & (OBJPC_SYNC | OBJPC_INVAL))
    ioflags |= IO_SYNC;
else if ((flags & OBJPC_CLUSTER_OK) == 0)
    ioflags |= IO_ASYNC;
ioflags |= IO_SEQMAX << IO_SEQSHIFT;
```

### File Size Changes

**`vnode_pager_setsize(vp, nsize)`**

Called when file size changes (truncate, extend):

1. Acquire object hold
2. If shrinking:
   - Update `object->size` and `vp->v_filesize`
   - Remove pages beyond new EOF via `vm_object_page_remove()`
   - Zero partial page at new EOF
   - Clear dirty bits for truncated portion
3. If extending:
   - Update `vp->v_filesize`

**Partial page handling on truncate:**
```c
if (nsize & PAGE_MASK) {
    m = vm_page_lookup_busy_wait(object, OFF_TO_IDX(nsize), TRUE, "vsetsz");
    if (m && m->valid) {
        /* Zero trailing bytes */
        bzero((caddr_t)kva + base, PAGE_SIZE - base);
        /* Unmap to sync all CPUs */
        vm_page_protect(m, VM_PROT_NONE);
        /* Clear partial dirty bits */
        vm_page_clear_dirty_beg_nonincl(m, base, size);
    }
}
```

### Vnode Locking Helper

**`vnode_pager_lock(ba)`**

Walks backing chain and locks the bottom-most vnode:

1. Find deepest backing_ba in chain
2. Get object from that backing
3. If object is `OBJT_VNODE` and not dead:
   - Call `vget(vp, LK_SHARED | LK_RETRY | LK_CANRECURSE)`
4. Retry on failure with 1-second sleep

Returns locked vnode or NULL.

## Memory Mapping (vm_mmap.c)

### System Calls Overview

| Syscall | Function | Description |
|---------|----------|-------------|
| `mmap` | `sys_mmap()` | Create memory mapping |
| `munmap` | `sys_munmap()` | Remove mapping |
| `mprotect` | `sys_mprotect()` | Change protection |
| `msync` | `sys_msync()` | Synchronize to backing store |
| `madvise` | `sys_madvise()` | Advise kernel about usage |
| `mlock` | `sys_mlock()` | Wire pages in memory |
| `munlock` | `sys_munlock()` | Unwire pages |
| `mlockall` | `sys_mlockall()` | Wire entire address space |
| `munlockall` | `sys_munlockall()` | Unwire entire address space |
| `mincore` | `sys_mincore()` | Query page residency |
| `minherit` | `sys_minherit()` | Set inheritance |

### mmap Implementation

**`sys_mmap(sysmsg, uap)`**

Entry point for mmap() system call:

1. Handle `MAP_STACK` → convert to `MAP_ANON` (stack auto-grow disabled for userland)
2. Call `kern_mmap()`

**`kern_mmap(vms, uaddr, ulen, uprot, uflags, fd, upos, res)`**

Main mmap implementation:

**Validation:**
```c
if ((flags & MAP_ANON) && (fd != -1 || pos != 0))
    return (EINVAL);
if (size == 0)
    return (EINVAL);
if (flags & MAP_STACK) {
    if (fd != -1)
        return (EINVAL);
    if ((prot & (PROT_READ|PROT_WRITE)) != (PROT_READ|PROT_WRITE))
        return (EINVAL);
    flags |= MAP_ANON;
}
```

**Address alignment:**
```c
pageoff = (pos & PAGE_MASK);
pos -= pageoff;
size += pageoff;
size = round_page(size);
```

**File mapping setup:**

For `fd != -1`:
1. Get file pointer via `holdfp()`
2. Validate file type is `DTYPE_VNODE`
3. Handle `FPOSIXSHM` → add `MAP_NOSYNC`
4. Check vnode type (VREG, VCHR allowed)
5. Validate protections against file open mode
6. Handle `/dev/zero` as anonymous

**Protection calculation:**
```c
maxprot = VM_PROT_EXECUTE;
if (fp->f_flag & FREAD)
    maxprot |= VM_PROT_READ;
if ((flags & MAP_SHARED) && (fp->f_flag & FWRITE))
    maxprot |= VM_PROT_WRITE;  /* Check IMMUTABLE/APPEND */
```

**Entry limit:**
```c
if (max_proc_mmap && vms->vm_map.nentries >= max_proc_mmap)
    return (ENOMEM);
```

**`vm_mmap(map, addr, size, prot, maxprot, flags, handle, foff, fp)`**

Internal mmap implementation:

1. Check RLIMIT_VMEM
2. Validate page-aligned file offset
3. Calculate alignment:
   - `MAP_SIZEALIGN`: align to size (must be power of 2)
   - Large mappings (≥ SEG_SIZE or > 16×SEG_SIZE): SEG_SIZE align
   - Otherwise: PAGE_SIZE align

**Object lookup:**
```c
if (flags & MAP_ANON) {
    if (handle)
        object = default_pager_alloc(handle, objsize, prot, foff);
    else
        object = NULL;  /* Deferred allocation */
} else {
    vp = (struct vnode *)handle;
    if (vp->v_type == VCHR && vp->v_rdev->si_ops->d_uksmap) {
        /* UKSMAP device mapping */
        uksmap = vp->v_rdev->si_ops->d_uksmap;
        object = NULL;
    } else if (vp->v_type == VCHR) {
        /* Device mapping */
        object = dev_pager_alloc(...);
    } else {
        /* Regular file */
        object = vnode_pager_reference(vp);
    }
}
```

**Map entry creation:**
```c
if (uksmap) {
    rv = vm_map_find(map, uksmap, vp->v_rdev, foff, addr, size,
                     align, fitit, VM_MAPTYPE_UKSMAP, ...);
} else if (flags & MAP_STACK) {
    rv = vm_map_stack(map, addr, size, flags, prot, maxprot, docow);
} else {
    rv = vm_map_find(map, object, NULL, foff, addr, size,
                     align, fitit, VM_MAPTYPE_NORMAL, ...);
}
```

**Post-processing:**
- Set `VM_INHERIT_SHARE` for `MAP_SHARED`/`MAP_INHERIT`
- Wire if `MAP_WIREFUTURE` is set
- Update vnode access time

### munmap Implementation

**`sys_munmap(sysmsg, uap)`**

1. Page-align address and size
2. Validate address range within user space
3. Check entire range is allocated via `vm_map_check_protection()`
4. Call `vm_map_remove()`

### mprotect Implementation

**`sys_mprotect(sysmsg, uap)`**

1. Page-align address and size
2. Call `vm_map_protect()` with new protection
3. Return appropriate errno for kernel result

### msync Implementation

**`sys_msync(sysmsg, uap)`**

1. Page-align address and size
2. Validate flags (MS_ASYNC|MS_INVALIDATE mutually exclusive)
3. If size == 0: find containing map entry, use its range
4. Call `vm_map_clean()` with sync/invalidate flags

### madvise/mcontrol Implementation

**`sys_madvise(sysmsg, uap)`**

Calls `vm_map_madvise()` with behavior:

| Behavior | Action |
|----------|--------|
| `MADV_NORMAL` | Reset to default |
| `MADV_SEQUENTIAL` | Expect sequential access |
| `MADV_RANDOM` | Expect random access |
| `MADV_WILLNEED` | Prefault pages |
| `MADV_DONTNEED` | May discard pages |
| `MADV_FREE` | May free pages |
| `MADV_NOSYNC` | Don't sync to disk |
| `MADV_AUTOSYNC` | Resume sync |
| `MADV_NOCORE` | Exclude from core dump |
| `MADV_CORE` | Include in core dump |
| `MADV_INVAL` | Invalidate pages |

**`sys_mcontrol(sysmsg, uap)`**

Extended madvise with value parameter.

### mincore Implementation

**`sys_mincore(sysmsg, uap)`**

Reports page residency:

1. Lock map for reading
2. For each page in range:
   - Check pmap first (`pmap_mincore()`)
   - If not in pmap, check VM object for resident page
   - Build result flags: `MINCORE_INCORE`, `MINCORE_MODIFIED_OTHER`, `MINCORE_REFERENCED_OTHER`
3. Write results to user byte vector
4. Restart if map changed during scan

### mlock/munlock Implementation

**`sys_mlock(sysmsg, uap)`**

1. Check against `vm_page_max_wired` limit
2. Check privilege or `RLIMIT_MEMLOCK`
3. Call `vm_map_user_wiring()` with `FALSE` (wire)

**`sys_munlock(sysmsg, uap)`**

1. Check privilege
2. Call `vm_map_user_wiring()` with `TRUE` (unwire)

### mlockall/munlockall Implementation

**`sys_mlockall(sysmsg, uap)`**

1. Check privilege
2. If `MCL_CURRENT`: wire all existing entries
3. If `MCL_FUTURE`: set `MAP_WIREFUTURE` flag

**`sys_munlockall(sysmsg, uap)`**

1. Clear `MAP_WIREFUTURE`
2. Unwire all user-wired entries
3. Handle in-transition entries with retry

### minherit Implementation

**`sys_minherit(sysmsg, uap)`**

Sets fork inheritance via `vm_map_inherit()`:

| Inheritance | Behavior |
|-------------|----------|
| `VM_INHERIT_NONE` | Not inherited |
| `VM_INHERIT_COPY` | COW copy (default) |
| `VM_INHERIT_SHARE` | Share with child |

## Key Sysctls

| Sysctl | Default | Description |
|--------|---------|-------------|
| `vm.max_proc_mmap` | 1000000 | Max map entries per process |
| `vm.vkernel_enable` | 0 | Enable vkernel features |

## DragonFly-Specific Features

### UKSMAP Device Mappings

Devices can provide direct user-kernel shared memory via `d_uksmap`:

```c
if (vp->v_type == VCHR && vp->v_rdev->si_ops->d_uksmap) {
    uksmap = vp->v_rdev->si_ops->d_uksmap;
    object = NULL;  /* No VM object */
    flags |= MAP_SHARED;
}
```

Used for `/dev/upmap`, `/dev/kpmap`, `/dev/lpmap`.

### MAP_STACK Handling

User MAP_STACK is converted to MAP_ANON:

```c
if (flags & MAP_STACK) {
    flags &= ~MAP_STACK;
    flags |= MAP_ANON;
}
```

Only the exec-created user stack uses true MAP_STACK internally.

### Alignment Optimization

Large mappings are aligned to SEG_SIZE for MMU optimization:

```c
if ((flags & MAP_FIXED) == 0 &&
    ((size & SEG_MASK) == 0 || size > SEG_SIZE * 16)) {
    align = SEG_SIZE;
}
```

### Address Hint

Non-fixed mappings get ASLR-randomized hint:

```c
addr = vm_map_hint(p, addr, prot, flags);
```

### POSIX Shared Memory

Files opened with `shm_open()` set `FPOSIXSHM`:

```c
if (fp->f_flag & FPOSIXSHM)
    flags |= MAP_NOSYNC;
```

## Function Reference

### Vnode Pager

| Function | Description |
|----------|-------------|
| `vnode_pager_alloc()` | Create/reference vnode object |
| `vnode_pager_reference()` | Reference existing object |
| `vnode_pager_dealloc()` | Destroy vnode object |
| `vnode_pager_haspage()` | Check file backing |
| `vnode_pager_getpage()` | Page in from file |
| `vnode_pager_putpages()` | Page out to file |
| `vnode_pager_generic_getpages()` | Generic page-in implementation |
| `vnode_pager_generic_putpages()` | Generic page-out implementation |
| `vnode_pager_setsize()` | Handle file size change |
| `vnode_pager_freepage()` | Release page from getpages |
| `vnode_pager_lock()` | Lock backing vnode |

### Memory Mapping

| Function | Description |
|----------|-------------|
| `kern_mmap()` | Internal mmap implementation |
| `vm_mmap()` | Core mapping function |
| `sys_mmap()` | mmap syscall handler |
| `sys_munmap()` | munmap syscall handler |
| `sys_mprotect()` | mprotect syscall handler |
| `sys_msync()` | msync syscall handler |
| `sys_madvise()` | madvise syscall handler |
| `sys_mcontrol()` | mcontrol syscall handler |
| `sys_mincore()` | mincore syscall handler |
| `sys_mlock()` | mlock syscall handler |
| `sys_munlock()` | munlock syscall handler |
| `sys_mlockall()` | mlockall syscall handler |
| `sys_munlockall()` | munlockall syscall handler |
| `sys_minherit()` | minherit syscall handler |
| `vm_mmap_to_errno()` | Convert VM return to errno |

## See Also

- [Address Space](vm_map.md) - Map entry management
- [VM Objects](vm_object.md) - Object lifecycle
- [Page Faults](vm_fault.md) - Fault handling for mapped pages
- [Pageout and Swap](vm_pageout.md) - Anonymous page backing
