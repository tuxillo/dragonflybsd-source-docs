# VFS Extensions and Helpers

## Overview

This document covers several VFS subsystems that extend the core VFS functionality:

- **VFS Helper Functions** (`vfs_helper.c`) - UNIX permission checking and attribute modification
- **Filesystem Synchronization** (`vfs_sync.c`) - Per-mount syncer daemon and dirty vnode management
- **Synthetic Filesystem** (`vfs_synth.c`) - Early boot devfs access for root device lookup
- **VFS Quota System** (`vfs_quota.c`) - Per-user/group space accounting and limits
- **Asynchronous I/O** (`vfs_aio.c`) - POSIX AIO stubs (not implemented)

## VFS Helper Functions

The `vfs_helper.c` file provides filesystem-agnostic implementations of common UNIX operations. These helpers allow filesystems to share code for permission checking, ownership changes, and file attribute modification.

**Key files:**
- `sys/kern/vfs_helper.c` - Helper function implementations

### Permission Checking (vop_helper_access)

Standard UNIX permission semantics for `VOP_ACCESS`:

```c
int vop_helper_access(struct vop_access_args *ap, uid_t ino_uid, gid_t ino_gid,
                      mode_t ino_mode, u_int32_t ino_flags)
```

**Permission check order:**
1. Check read-only filesystem for write attempts
2. Check immutable flag (`IMMUTABLE`) for write attempts
3. Allow root (uid 0) unconditional access
4. Check owner permissions if `proc_uid == ino_uid`
5. Check group permissions if `proc_gid == ino_gid` or user is in supplementary group
6. Check "other" permissions

**AT_EACCESS support:**
```c
if (ap->a_flags & AT_EACCESS) {
    proc_uid = cred->cr_uid;   /* effective uid */
    proc_gid = cred->cr_gid;   /* effective gid */
} else {
    proc_uid = cred->cr_ruid;  /* real uid */
    proc_gid = cred->cr_rgid;  /* real gid */
}
```

### File Attribute Modification

**`vop_helper_setattr_flags()`** - Modify file flags (chflags):

```c
int vop_helper_setattr_flags(u_int32_t *ino_flags, u_int32_t vaflags,
                             uid_t uid, struct ucred *cred)
```

- Non-owner requires `SYSCAP_NOVFS_SYSFLAGS` capability
- Root can set system flags (`SF_*`) unless securelevel > 0
- Regular users can only modify user flags (`UF_SETTABLE`)
- Jail restrictions apply via `PRISON_CAP_VFS_CHFLAGS`

**`vop_helper_chmod()`** - Change file mode:

```c
int vop_helper_chmod(struct vnode *vp, mode_t new_mode, struct ucred *cred,
                     uid_t cur_uid, gid_t cur_gid, mode_t *cur_modep)
```

- Non-owner requires `SYSCAP_NOVFS_CHMOD` capability
- Non-root users cannot set sticky bit on non-directories
- Non-root users cannot set SGID if not in file's group

**`vop_helper_chown()`** - Change file ownership:

```c
int vop_helper_chown(struct vnode *vp, uid_t new_uid, gid_t new_gid,
                     struct ucred *cred,
                     uid_t *cur_uidp, gid_t *cur_gidp, mode_t *cur_modep)
```

- Non-owner requires `SYSCAP_NOVFS_CHOWN` capability
- Changing owner or group clears SUID/SGID bits (unless root)
- Validates group membership for non-privileged users

**`vop_helper_create_uid()`** - Determine new file ownership:

```c
uid_t vop_helper_create_uid(struct mount *mp, mode_t dmode, uid_t duid,
                            struct ucred *cred, mode_t *modep)
```

- Supports `SUIDDIR` mount option (files inherit directory owner)
- Otherwise returns creator's uid

### VM Read Shortcut

**`vop_helper_read_shortcut()`** - Bypass VFS for cached reads:

When `LWBUF_IS_OPTIMAL` is defined, this function attempts to read directly from VM pages without going through the buffer cache:

```c
int vop_helper_read_shortcut(struct vop_read_args *ap)
{
    // Check prerequisites
    if (vp->v_object == NULL || uio->uio_segflg == UIO_NOCOPY)
        return 0;  // Fall back to normal path
    
    vm_object_hold_shared(obj);
    
    while (uio->uio_resid && error == 0) {
        // Look up page in VM object
        m = vm_page_lookup_sbusy_try(obj, OFF_TO_IDX(uio->uio_offset), ...);
        if (m == NULL || (m->valid & VM_PAGE_BITS_ALL) != VM_PAGE_BITS_ALL)
            break;  // Fall back to normal path
        
        // Copy directly from page
        lwb = lwbuf_alloc(m, &lwb_cache);
        error = uiomove_nofault((char *)lwbuf_kva(lwb) + offset, n, uio);
        lwbuf_free(lwb);
        vm_page_sbusy_drop(m);
    }
    
    vm_object_drop(obj);
    return error;
}
```

Controlled via sysctl `vm.read_shortcut_enable`.

## Filesystem Synchronization

The `vfs_sync.c` file implements per-filesystem syncer daemons that periodically flush dirty data to disk.

**Key files:**
- `sys/kern/vfs_sync.c` - Syncer daemon and worklist management

### Architecture

Each mounted filesystem with `MNTK_THR_SYNC` gets its own syncer thread:

```
                    ┌─────────────────┐
                    │  syncer_thread  │
                    │   (per mount)   │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        v                    v                    v
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ workitem[0]  │    │ workitem[1]  │    │ workitem[N]  │
│  (sync now)  │    │ (sync +1s)   │    │ (sync +Ns)   │
└──────────────┘    └──────────────┘    └──────────────┘
```

### Syncer Context Structure

```c
struct syncer_ctx {
    struct mount        *sc_mp;
    struct lwkt_token   sc_token;
    struct thread       *sc_thread;
    int                 sc_flags;
    struct synclist     *syncer_workitem_pending;  /* Hash table */
    long                syncer_mask;               /* Hash mask */
    int                 syncer_delayno;            /* Current slot */
    int                 syncer_forced;             /* Force sync mode */
    int                 syncer_rushjob;            /* Rush sync mode */
    int                 syncer_trigger;            /* Trigger full sync */
    long                syncer_count;              /* Vnodes on lists */
};
```

### Delay Parameters

Tunable via sysctl:

| Parameter | Default | Sysctl | Description |
|-----------|---------|--------|-------------|
| `syncdelay` | 30s | `kern.syncdelay` | Max delay for data sync |
| `filedelay` | 30s | `kern.filedelay` | File data sync delay |
| `dirdelay` | 29s | `kern.dirdelay` | Directory sync delay |
| `metadelay` | 28s | `kern.metadelay` | Metadata sync delay |
| `retrydelay` | 1s | `kern.retrydelay` | Retry delay after failure |

### Worklist Management

**Adding vnodes to syncer worklist:**

```c
void vn_syncer_add(struct vnode *vp, int delay)
{
    ctx = vp->v_mount->mnt_syncer_ctx;
    lwkt_gettoken(&ctx->sc_token);
    
    if (vp->v_flag & VONWORKLST) {
        LIST_REMOVE(vp, v_synclist);
        --ctx->syncer_count;
    }
    
    slot = (ctx->syncer_delayno + delay) & ctx->syncer_mask;
    LIST_INSERT_HEAD(&ctx->syncer_workitem_pending[slot], vp, v_synclist);
    vsetflags(vp, VONWORKLST);
    ++ctx->syncer_count;
    
    lwkt_reltoken(&ctx->sc_token);
}
```

**Removing vnodes from worklist:**

```c
void vn_syncer_remove(struct vnode *vp, int force)
```

Called when vnode is no longer dirty or during forced unmount.

### Dirty Vnode Tracking

**`vsetisdirty(vp)`** - Mark vnode as having dirty inode data:

```c
void vsetisdirty(struct vnode *vp)
{
    if ((vp->v_flag & VISDIRTY) == 0) {
        vsetflags(vp, VISDIRTY);
        if ((vp->v_flag & VONWORKLST) == 0)
            vn_syncer_add(vp, syncdelay);
    }
}
```

**`vsetobjdirty(vp)`** - Mark vnode as having dirty VM object:

```c
void vsetobjdirty(struct vnode *vp)
{
    if ((vp->v_flag & VOBJDIRTY) == 0) {
        vsetflags(vp, VOBJDIRTY);
        if ((vp->v_flag & VONWORKLST) == 0)
            vn_syncer_add(vp, syncdelay);
    }
}
```

### Syncer Thread Operation

The syncer thread runs a continuous loop:

```c
static void syncer_thread(void *_ctx)
{
    for (;;) {
        // 1. Handle triggered full sync
        if (ctx->syncer_trigger) {
            VOP_FSYNC(ctx->sc_mp->mnt_syncer, MNT_LAZY, 0);
            atomic_clear_int(&ctx->syncer_trigger, 1);
        }
        
        // 2. Process current time slot
        slp = &ctx->syncer_workitem_pending[ctx->syncer_delayno];
        while ((vp = LIST_FIRST(slp)) != NULL) {
            vn_syncer_add(vp, retrydelay);  // Move to retry slot
            if (vget(vp, LK_EXCLUSIVE | LK_NOWAIT) == 0) {
                VOP_FSYNC(vp, MNT_LAZY, 0);
                vput(vp);
            }
        }
        
        // 3. Advance to next slot
        ctx->syncer_delayno = (ctx->syncer_delayno + 1) & ctx->syncer_mask;
        
        // 4. Sleep until next second (or wakeup)
        tsleep(ctx, PINTERLOCKED, "syncer", hz);
    }
}
```

### Syncer Control Functions

**`speedup_syncer(mp)`** - Request faster sync processing:

```c
void speedup_syncer(struct mount *mp)
{
    atomic_add_int(&rushjob, 1);
    if (mp && mp->mnt_syncer_ctx)
        wakeup(mp->mnt_syncer_ctx);
}
```

**`trigger_syncer(mp)`** - Request immediate full sync:

```c
void trigger_syncer(struct mount *mp)
{
    if (mp && (ctx = mp->mnt_syncer_ctx) != NULL) {
        atomic_set_int(&ctx->syncer_trigger, 1);
        wakeup(ctx);
    }
}
```

**`trigger_syncer_start(mp)` / `trigger_syncer_stop(mp)`** - Continuous sync mode:

Used by filesystems that need guaranteed sync progress (e.g., waiting for dirty data flush).

### Syncer Vnode

Each mount point has a special syncer vnode (`mp->mnt_syncer`) that:
- Is always on the syncer worklist
- Triggers `VFS_SYNC()` when its turn comes
- Has minimal vnode operations (just fsync, inactive, reclaim)

```c
int vfs_allocate_syncvnode(struct mount *mp)
{
    error = getspecialvnode(VT_VFS, mp, &sync_vnode_vops_p, &vp, 0, 0);
    vp->v_type = VNON;
    vn_syncer_add(vp, next % syncdelay);
    mp->mnt_syncer = vp;
    return 0;
}
```

### vsyncscan() - Efficient Dirty Vnode Iteration

For filesystems with many vnodes, iterating all mount vnodes is expensive. `vsyncscan()` iterates only vnodes on the syncer worklist:

```c
int vsyncscan(struct mount *mp, int vmsc_flags,
              int (*slowfunc)(struct mount *mp, struct vnode *vp, void *data),
              void *data)
```

Flags:
- `VMSC_NOWAIT` - Use non-blocking vnode acquisition
- `VMSC_GETVP` - Acquire vnode lock before callback
- `VMSC_GETVX` - Acquire VX lock before callback

## Synthetic Filesystem

The `vfs_synth.c` file provides a synthetic devfs mount used during early boot to locate root devices.

**Key files:**
- `sys/kern/vfs_synth.c` - Synthetic filesystem initialization

### Purpose

During boot, the kernel needs to find the root device before the normal filesystem hierarchy is mounted. The synthetic filesystem:

1. Creates an internal devfs mount (`synth_mp`)
2. Provides `getsynthvnode()` to look up device nodes by name
3. Triggers `sync_devs()` to ensure devices are enumerated

### Initialization

```c
static void synthinit(void *arg __unused)
{
    // Create internal devfs mount
    error = vfs_rootmountalloc("devfs", "dummy", &synth_mp);
    error = VFS_MOUNT(synth_mp, NULL, NULL, proc0.p_ucred);
    error = VFS_ROOT(synth_mp, &synth_vp);
    
    // Set up namecache for lookups
    cache_allocroot(&synth_mp->mnt_ncmountpt, synth_mp, synth_vp);
    cache_unlock(&synth_mp->mnt_ncmountpt);
    vput(synth_vp);
    
    synth_inited = 1;
}

SYSINIT(synthinit, SI_SUB_VFS, SI_ORDER_ANY, synthinit, NULL);
```

### Device Lookup

```c
struct vnode *getsynthvnode(const char *devname)
{
    KKASSERT(synth_inited != 0);
    
    // Sync devfs twice to ensure devices are present
    if (synth_synced < 2) {
        sync_devs();
        ++synth_synced;
    }
    
    // Look up device in synthetic devfs
    error = nlookup_init_root(&nd, devname, UIO_SYSSPACE, NLC_FOLLOW,
                              cred, &synth_mp->mnt_ncmountpt,
                              &synth_mp->mnt_ncmountpt);
    error = nlookup(&nd);
    
    if (error == 0) {
        vp = nch.ncp->nc_vp;
        error = vget(vp, LK_EXCLUSIVE);
    }
    
    nlookup_done(&nd);
    return vp;  // Returns VX-locked, referenced vnode
}
```

## VFS Quota System

The `vfs_quota.c` file implements per-user and per-group space accounting and limits.

**Key files:**
- `sys/kern/vfs_quota.c` - Quota implementation
- `sys/sys/vfs_quota.h` - Quota data structures

### Enabling Quotas

Quotas are disabled by default and controlled via:
- Boot-time tunable: `vfs.quota_enabled`
- Sysctl: `vfs.quota_enabled` (read-only)

### Data Structures

Per-mount accounting uses red-black trees for efficient uid/gid lookup:

```c
struct ac_unode {
    RB_ENTRY(ac_unode) rb_entry;
    uint32_t left_bits;        /* uid >> ACCT_CHUNK_BITS */
    struct {
        int64_t space;         /* bytes used */
        int64_t limit;         /* byte limit (0 = unlimited) */
    } uid_chunk[ACCT_CHUNK_NIDS];
};

struct ac_gnode {
    RB_ENTRY(ac_gnode) rb_entry;
    uint32_t left_bits;        /* gid >> ACCT_CHUNK_BITS */
    struct {
        int64_t space;
        int64_t limit;
    } gid_chunk[ACCT_CHUNK_NIDS];
};
```

Chunked storage reduces tree nodes: each node handles `ACCT_CHUNK_NIDS` consecutive uid/gids.

### Initialization

```c
void vq_init(struct mount *mp)
{
    if (!vfs_quota_enabled)
        return;
    
    RB_INIT(&mp->mnt_acct.ac_uroot);
    RB_INIT(&mp->mnt_acct.ac_groot);
    spin_init(&mp->mnt_acct.ac_spin, "vqinit");
    
    mp->mnt_acct.ac_bytes = 0;
    mp->mnt_op->vfs_account = vfs_stdaccount;
    mp->mnt_flag |= MNT_QUOTA;
}
```

### Accounting Callback

Filesystems call `vfs_account()` on space changes:

```c
void vfs_stdaccount(struct mount *mp, uid_t uid, gid_t gid, int64_t delta)
{
    spin_lock(&mp->mnt_acct.ac_spin);
    
    mp->mnt_acct.ac_bytes += delta;
    
    // Find or create uid node
    ufind.left_bits = (uid >> ACCT_CHUNK_BITS);
    if ((unp = RB_FIND(ac_utree, &mp->mnt_acct.ac_uroot, &ufind)) == NULL)
        unp = unode_insert(mp, uid);
    
    // Find or create gid node
    gfind.left_bits = (gid >> ACCT_CHUNK_BITS);
    if ((gnp = RB_FIND(ac_gtree, &mp->mnt_acct.ac_groot, &gfind)) == NULL)
        gnp = gnode_insert(mp, gid);
    
    // Update usage
    unp->uid_chunk[(uid & ACCT_CHUNK_MASK)].space += delta;
    gnp->gid_chunk[(gid & ACCT_CHUNK_MASK)].space += delta;
    
    spin_unlock(&mp->mnt_acct.ac_spin);
}
```

### Quota Enforcement

**`vq_write_ok()`** - Check if write is allowed:

```c
int vq_write_ok(struct mount *mp, uid_t uid, gid_t gid, uint64_t delta)
{
    spin_lock(&mp->mnt_acct.ac_spin);
    
    // Check filesystem limit
    if (mp->mnt_acct.ac_limit &&
        (mp->mnt_acct.ac_bytes + delta) > mp->mnt_acct.ac_limit) {
        rv = 0;
        goto done;
    }
    
    // Check uid limit
    if (unp && unp->uid_chunk[...].limit &&
        (space + delta) > limit) {
        rv = 0;
        goto done;
    }
    
    // Check gid limit
    if (gnp && gnp->gid_chunk[...].limit &&
        (space + delta) > limit) {
        rv = 0;
    }
    
done:
    spin_unlock(&mp->mnt_acct.ac_spin);
    return rv;
}
```

### System Call Interface

**`sys_vquotactl()`** - Quota control system call:

Commands (via proplib dictionary):
- `"get usage all"` - Return all usage statistics
- `"set usage all"` - Set usage statistics (for restore)
- `"set limit"` - Set filesystem-wide limit
- `"set limit uid"` - Set per-uid limit
- `"set limit gid"` - Set per-gid limit

### PFS Support

For pseudo-filesystems (nullfs, etc.), `vq_vptomp()` returns the real mount point:

```c
struct mount *vq_vptomp(struct vnode *vp)
{
    if ((vp->v_pfsmp != NULL) && (mountlist_exists(vp->v_pfsmp)))
        return vp->v_pfsmp;  /* Real mount for PFS */
    else
        return vp->v_mount;
}
```

## Asynchronous I/O (Stubs)

The `vfs_aio.c` file contains **stub implementations** of POSIX AIO functions. These system calls are **not implemented** in DragonFly BSD and return `ENOSYS`:

```c
int sys_aio_read(struct sysmsg *sysmsg, const struct aio_read_args *uap)
{
    return ENOSYS;
}

int sys_aio_write(struct sysmsg *sysmsg, const struct aio_write_args *uap)
{
    return ENOSYS;
}

int sys_aio_return(struct sysmsg *sysmsg, const struct aio_return_args *uap)
{
    return ENOSYS;
}

int sys_aio_suspend(struct sysmsg *sysmsg, const struct aio_suspend_args *uap)
{
    return ENOSYS;
}

int sys_aio_cancel(struct sysmsg *sysmsg, const struct aio_cancel_args *uap)
{
    return ENOSYS;
}

int sys_aio_error(struct sysmsg *sysmsg, const struct aio_error_args *uap)
{
    return ENOSYS;
}

int sys_lio_listio(struct sysmsg *sysmsg, const struct lio_listio_args *uap)
{
    return ENOSYS;
}

int sys_aio_waitcomplete(struct sysmsg *sysmsg, const struct aio_waitcomplete_args *uap)
{
    return ENOSYS;
}
```

The kevent filter for AIO also returns `ENXIO`:

```c
static int filt_aioattach(struct knote *kn)
{
    return ENXIO;
}

struct filterops aio_filtops =
    { FILTEROP_MPSAFE, filt_aioattach, NULL, NULL };
```

## Summary

| Subsystem | File | Lines | Purpose |
|-----------|------|-------|---------|
| VFS Helpers | `vfs_helper.c` | 405 | UNIX permission/attribute helpers |
| Syncer | `vfs_sync.c` | 890 | Per-mount syncer daemon |
| Synthetic FS | `vfs_synth.c` | 137 | Early boot devfs access |
| Quotas | `vfs_quota.c` | 486 | Space accounting and limits |
| AIO | `vfs_aio.c` | 83 | POSIX AIO stubs (not implemented) |

Key design points:

1. **Helper functions** provide consistent UNIX semantics across filesystems
2. **Per-mount syncers** scale better than a single global syncer
3. **Quota system** uses chunked RB-trees for efficient uid/gid tracking
4. **Synthetic filesystem** enables device lookup before root mount
5. **AIO is unimplemented** - applications should use alternatives
