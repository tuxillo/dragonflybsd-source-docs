# System V Shared Memory

System V shared memory allows processes to share memory regions directly.
DragonFly's implementation derives from FreeBSD and uses VM objects backed
by either physical memory or the swap pager.

**Source files:**
- `sys/kern/sysv_shm.c` - Implementation
- `sys/sys/shm.h` - Public interface

## Data Structures

### Shared Memory Descriptor

```c
struct shmid_ds {
    struct ipc_perm shm_perm;   /* permission structure */
    size_t    shm_segsz;        /* segment size in bytes */
    pid_t     shm_lpid;         /* last shmat/shmdt pid */
    pid_t     shm_cpid;         /* creator pid */
    shmatt_t  shm_nattch;       /* current attach count */
    time_t    shm_atime;        /* last shmat() time */
    time_t    shm_dtime;        /* last shmdt() time */
    time_t    shm_ctime;        /* last shmctl() time */
    void     *shm_internal;     /* kernel-internal handle */
};
```

Defined in `sys/sys/shm.h:74-84`.

### Internal Handle

```c
struct shm_handle {
    vm_object_t shm_object;  /* backing VM object */
};
```

Defined in `sys/kern/sysv_shm.c:71-74`. The `shm_internal` field of
`shmid_ds` points to this structure.

### Per-Process Mapping State

```c
struct shmmap_state {
    vm_offset_t va;     /* virtual address of mapping */
    int shmid;          /* attached segment id, or -1 */
    int reserved;       /* reservation flag for races */
};
```

Defined in `sys/kern/sysv_shm.c:76-80`. Each process has an array of
these (size `shmseg`) stored in `p->p_vmspace->vm_shm`.

## Segment State Flags

| Flag | Value | Description |
|------|-------|-------------|
| `SHMSEG_FREE` | 0x0200 | Slot is available |
| `SHMSEG_REMOVED` | 0x0400 | Marked for removal |
| `SHMSEG_ALLOCATED` | 0x0800 | Segment is in use |
| `SHMSEG_WANTED` | 0x1000 | Someone waiting for allocation |

Defined in `sys/kern/sysv_shm.c:62-65`.

## System Limits

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SHMMIN` | 1 | Minimum segment size |
| `SHMMNI` | 512 | Max segment identifiers |
| `SHMSEG` | 1024 | Max segments per process |
| `shmmax` | 2/3 RAM | Max segment size (auto-computed) |
| `shmall` | 2/3 RAM pages | Max total pages (auto-computed) |

If `shmall` is not set via tunable, it defaults to 2/3 of physical pages.
`shmmax` is computed as `shmall * PAGE_SIZE`.

Defined in `sys/kern/sysv_shm.c:92-108`.

## Configuration Options

### shm_use_phys

```c
static int shm_use_phys = 1;
```

When enabled, uses `phys_pager_alloc()` instead of `swap_pager_alloc()`.
Physical backing provides better performance for large segments by
allowing pmap optimizations. Pages are effectively wired.

When set to 2 or higher, pages are pre-allocated at segment creation
time, improving database warm-up times by enabling concurrent page
faults on already-existing pages.

### shm_allow_removed

```c
static int shm_allow_removed = 1;
```

When enabled, allows `shmat()` to attach to segments marked for removal
(`IPC_RMID`) as long as they still have references. Used by Chrome and
other applications to ensure cleanup after unexpected termination.

## Synchronization

A single LWKT token protects all shared memory operations:

```c
static struct lwkt_token shm_token = LWKT_TOKEN_INITIALIZER(shm_token);
```

The `reserved` field in `shmmap_state` prevents races when the token
is released during blocking operations in `shmat()`.

## Initialization

`shminit()` runs at `SI_SUB_SYSV_SHM`:

1. If `shmall == 0`, set to 2/3 of `v_page_count`
2. Compute `shmmax = shmall * PAGE_SIZE`
3. Allocate `shmsegs[]` array (SHMMNI entries)
4. Mark all slots as `SHMSEG_FREE`

See `sys/kern/sysv_shm.c:704-727`.

## System Calls

### shmget - Create or Access Segment

```c
int sys_shmget(struct sysmsg *sysmsg, const struct shmget_args *uap)
```

**Arguments:** `key`, `size`, `shmflg`

**Operation:**
1. If `key != IPC_PRIVATE`, search for existing segment
2. If found, call `shmget_existing()`:
   - If `SHMSEG_REMOVED` set, sleep and retry
   - Check `IPC_CREAT|IPC_EXCL` conflict
   - Validate permissions and size
3. If not found and `IPC_CREAT`, call `shmget_allocate_segment()`:
   - Validate size against limits
   - Check system-wide page commitment
   - Find free slot (may call `shmrealloc()` to expand)
   - Mark slot `ALLOCATED | REMOVED` during allocation
   - Allocate `shm_handle` and backing VM object
   - Choose `phys_pager` or `swap_pager` based on `shm_use_phys`
   - Optionally pre-fault pages if `shm_use_phys > 1`
   - Wake waiters if `SHMSEG_WANTED` was set

See `sys/kern/sysv_shm.c:610-644`, `464-605`.

### shmat - Attach Segment

```c
int sys_shmat(struct sysmsg *sysmsg, const struct shmat_args *uap)
```

**Arguments:** `shmid`, `shmaddr`, `shmflg`

**Operation:**
1. Allocate per-process `shmmap_state[]` array if needed
2. Find segment by shmid (respects `shm_allow_removed`)
3. Check permissions (`IPC_R` or `IPC_R|IPC_W`)
4. Find free slot in per-process array, mark `reserved = 1`
5. Calculate attach address:
   - If `shmaddr` given with `SHM_RND`, round down to `SHMLBA`
   - If `shmaddr` given without `SHM_RND`, must be `SHMLBA`-aligned
   - Otherwise, hint near end of data segment
6. For large segments aligned to `SEG_SIZE`, use `SEG_SIZE` alignment
7. Call `vm_map_find()` to map the VM object
8. Set `VM_INHERIT_SHARE` so mappings persist across fork
9. Update `shmmap_state`, increment `shm_nattch`

See `sys/kern/sysv_shm.c:260-395`.

### shmdt - Detach Segment

```c
int sys_shmdt(struct sysmsg *sysmsg, const struct shmdt_args *uap)
```

**Arguments:** `shmaddr`

**Operation:**
1. Find mapping in per-process array by address
2. Call `shm_delete_mapping()`:
   - `vm_map_remove()` the mapping
   - Clear the `shmmap_state` entry
   - Decrement `shm_nattch`
   - If `shm_nattch == 0` and `SHMSEG_REMOVED`, deallocate segment

See `sys/kern/sysv_shm.c:222-255`, `196-217`.

### shmctl - Control Operations

```c
int sys_shmctl(struct sysmsg *sysmsg, const struct shmctl_args *uap)
```

**Commands:**

| Command | Description |
|---------|-------------|
| `IPC_STAT` | Copy `shmid_ds` to user buffer |
| `IPC_SET` | Update uid, gid, mode |
| `IPC_RMID` | Mark segment for removal |

**IPC_RMID Operation:**
1. Set `shm_perm.key = IPC_PRIVATE` (prevents new lookups)
2. Set `SHMSEG_REMOVED` flag
3. If `shm_nattch == 0`, deallocate immediately
4. Otherwise, wait for all detaches

See `sys/kern/sysv_shm.c:400-462`.

## Segment Deallocation

```c
static void shm_deallocate_segment(struct shmid_ds *shmseg)
```

1. Get `shm_handle` from `shm_internal`
2. Release VM object reference (`vm_object_deallocate()`)
3. Free `shm_handle`
4. Decrease `shm_committed` by segment pages
5. Decrement `shm_nused`
6. Mark slot as `SHMSEG_FREE`

See `sys/kern/sysv_shm.c:180-194`.

## Fork and Exit Handling

### shmfork

Called when a process forks:

```c
void shmfork(struct proc *p1, struct proc *p2)
```

1. Allocate new `shmmap_state[]` for child
2. Copy parent's mappings
3. Increment `shm_nattch` for each attached segment

The `VM_INHERIT_SHARE` flag ensures the actual mappings are shared.

See `sys/kern/sysv_shm.c:646-663`.

### shmexit

Called when a process exits or execs:

```c
void shmexit(struct vmspace *vm)
```

1. Detach all attached segments via `shm_delete_mapping()`
2. Free the `shmmap_state[]` array

See `sys/kern/sysv_shm.c:665-681`.

## Dynamic Array Expansion

```c
static void shmrealloc(void)
```

If `shmalloced < shmmni`, reallocates `shmsegs[]` to full size.
Called during allocation when no free slots exist.

See `sys/kern/sysv_shm.c:683-702`.

## VM Object Backing

Two pager types are supported:

### Physical Pager (shm_use_phys = 1)

```c
shm_handle->shm_object = phys_pager_alloc(NULL, size, VM_PROT_DEFAULT, 0);
```

- Pages are wired in physical memory
- Better pmap optimization for large segments
- No swap backing

### Swap Pager (shm_use_phys = 0)

```c
shm_handle->shm_object = swap_pager_alloc(NULL, size, VM_PROT_DEFAULT, 0);
```

- Pages can be swapped out
- More flexible memory usage

Both set `OBJ_NOSPLIT` to prevent the object from being split.

## Jail Support

All system calls check jail capabilities:

```c
if (pr && !PRISON_CAP_ISSET(pr->pr_caps, PRISON_CAP_SYS_SYSVIPC))
    return (ENOSYS);
```

## Sysctl Interface

| Sysctl | Type | Description |
|--------|------|-------------|
| `kern.ipc.shmmax` | RW | Max segment size |
| `kern.ipc.shmmin` | RW | Min segment size |
| `kern.ipc.shmmni` | RD | Max identifiers |
| `kern.ipc.shmseg` | RW | Max segments per process |
| `kern.ipc.shmall` | RW | Max total pages |
| `kern.ipc.shm_use_phys` | RW | Use physical pager |
| `kern.ipc.shm_allow_removed` | RW | Allow attach to removed |

Boot tunables: `kern.ipc.shmmin`, `kern.ipc.shmmni`, `kern.ipc.shmseg`,
`kern.ipc.shmmaxpgs`, `kern.ipc.shm_use_phys`.

See `sys/kern/sysv_shm.c:126-146`.

## Error Handling

| Error | Condition |
|-------|-----------|
| `ENOSYS` | Jail lacks SYSVIPC capability |
| `EINVAL` | Invalid shmid, size, or address |
| `EEXIST` | `IPC_CREAT|IPC_EXCL` and segment exists |
| `ENOENT` | Segment not found, no `IPC_CREAT` |
| `ENOSPC` | No free slots |
| `ENOMEM` | Page commitment exceeded or mapping failed |
| `EMFILE` | Per-process segment limit reached |
| `EACCES` | Permission denied |
