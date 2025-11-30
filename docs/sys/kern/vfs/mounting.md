# VFS Mounting and Unmounting

## Overview

The VFS mounting subsystem manages filesystem mount points throughout their lifecycle, from initial allocation through mounting, operation, and eventual unmounting. This documentation covers the mount point management infrastructure in `vfs_mount.c` and the mount/unmount system calls in `vfs_syscalls.c`.

**Key source files:**
- `sys/kern/vfs_mount.c` (1,249 lines) - Mount point lifecycle and management
- `sys/kern/vfs_syscalls.c` (5,512+ lines) - VFS system calls including mount/unmount
- `sys/sys/mount.h` - Mount structure and flag definitions

## Mount Structure

### struct mount

The `struct mount` (defined in sys/sys/mount.h:216) is the central data structure representing a mounted filesystem instance:

```c
struct mount {
    TAILQ_ENTRY(mount) mnt_list;        /* mount list linkage */
    struct vfsops      *mnt_op;         /* filesystem operations */
    struct vfsconf     *mnt_vfc;        /* filesystem configuration */
    u_int              mnt_namecache_gen; /* negative cache invalidation */
    u_int              mnt_pbuf_count;  /* pbuf usage limit */
    struct vnode       *mnt_syncer;     /* syncer vnode */
    struct syncer_ctx  *mnt_syncer_ctx; /* syncer process context */
    struct vnodelst    mnt_nvnodelist;  /* list of vnodes on this mount */
    TAILQ_HEAD(,vmntvnodescan_info) mnt_vnodescan_list;
    struct lock        mnt_lock;        /* mount structure lock */
    int                mnt_flag;        /* user-visible flags */
    int                mnt_kern_flag;   /* kernel-only flags */
    int                mnt_maxsymlinklen; /* max short symlink size */
    struct statfs      mnt_stat;        /* filesystem statistics */
    struct statvfs     mnt_vstat;       /* extended statistics */
    qaddr_t            mnt_data;        /* filesystem-private data */
    time_t             mnt_time;        /* last write time */
    u_int              mnt_iosize_max;  /* max IO request size */
    struct vnodelst    mnt_reservedvnlist; /* reserved/dirty vnode list */
    int                mnt_nvnodelistsize; /* vnode list size */
    
    /* VFS operations vectors (stacked) */
    struct vop_ops     *mnt_vn_use_ops;      /* current ops */
    struct vop_ops     *mnt_vn_coherency_ops; /* cache coherency */
    struct vop_ops     *mnt_vn_journal_ops;   /* journaling */
    struct vop_ops     *mnt_vn_norm_ops;      /* normal ops */
    struct vop_ops     *mnt_vn_spec_ops;      /* special files */
    struct vop_ops     *mnt_vn_fifo_ops;      /* FIFOs */
    
    /* Namecache integration */
    struct nchandle    mnt_ncmountpt;   /* mount point (root of fs) */
    struct nchandle    mnt_ncmounton;   /* mounted on (directory) */
    
    /* Reference counting */
    struct ucred       *mnt_cred;       /* credentials */
    int                mnt_refs;        /* nchandle references */
    int                mnt_hold;        /* prevent premature free */
    struct lwkt_token  mnt_token;       /* token lock if !MPSAFE */
    
    /* Journaling support */
    struct journallst  mnt_jlist;       /* active journals */
    u_int8_t           *mnt_jbitmap;    /* streamid bitmap */
    int16_t            mnt_streamid;    /* last streamid */
    
    /* Buffer I/O operations */
    struct bio_ops     *mnt_bioops;     /* BIO ops (HAMMER, softupd) */
    struct lock        mnt_renlock;     /* rename directory lock */
    
    /* Quota accounting */
    struct vfs_acct    mnt_acct;        /* space accounting */
    RB_ENTRY(mount)    mnt_node;        /* mounttree RB-tree node */
};
```

**Key nchandle fields:**
- `mnt_ncmountpt`: Points to the root of the mounted filesystem (created during mount)
- `mnt_ncmounton`: Points to the directory where the filesystem is mounted

### Mount Flags (mnt_flag)

User-visible flags in `mnt_flag` (sys/sys/mount.h:274):

**Access control:**
- `MNT_RDONLY` (0x00000001) - Read-only filesystem
- `MNT_NOSUID` (0x00000008) - Ignore setuid/setgid bits
- `MNT_NOEXEC` (0x00000004) - Disallow program execution
- `MNT_NODEV` (0x00000010) - Ignore device files

**Performance:**
- `MNT_SYNCHRONOUS` (0x00000002) - Synchronous writes
- `MNT_ASYNC` (0x00000040) - Asynchronous writes
- `MNT_NOATIME` (0x10000000) - Don't update access times
- `MNT_NOCLUSTERR` (0x40000000) - Disable cluster read
- `MNT_NOCLUSTERW` (0x80000000) - Disable cluster write

**Special behavior:**
- `MNT_NOSYMFOLLOW` (0x00400000) - Don't follow symlinks
- `MNT_SUIDDIR` (0x00100000) - Special SUID directory handling
- `MNT_TRIM` (0x01000000) - Enable online FS trimming
- `MNT_AUTOMOUNTED` (0x00000020) - Mounted by automountd(8)

**NFS export:**
- `MNT_EXPORTED` (0x00000100) - Filesystem is exported
- `MNT_DEFEXPORTED` (0x00000200) - Exported to the world
- `MNT_EXRDONLY` (0x00000080) - Exported read-only

**Internal:**
- `MNT_LOCAL` (0x00001000) - Stored locally
- `MNT_QUOTA` (0x00002000) - Quotas enabled
- `MNT_ROOTFS` (0x00004000) - Root filesystem
- `MNT_USER` (0x00008000) - Mounted by non-root user
- `MNT_IGNORE` (0x00800000) - Hide from df output

**Command flags (transient):**
- `MNT_UPDATE` (0x00010000) - Update existing mount
- `MNT_RELOAD` (0x00040000) - Reload filesystem data
- `MNT_FORCE` (0x00080000) - Force unmount/readonly change

### Kernel Flags (mnt_kern_flag)

Kernel-only flags in `mnt_kern_flag` (sys/sys/mount.h:348):

**Unmounting:**
- `MNTK_UNMOUNT` (0x01000000) - Unmount in progress
- `MNTK_UNMOUNTF` (0x00000001) - Forced unmount in progress
- `MNTK_MWAIT` (0x02000000) - Waiting for unmount to finish
- `MNTK_QUICKHALT` (0x00008000) - Quick unmount on system halt

**MPSAFE operation flags:**
- `MNTK_ALL_MPSAFE` - All VFS operations are MPSAFE
- `MNTK_MPSAFE` (0x00010000) - VFS operations don't need mnt_token
- `MNTK_RD_MPSAFE` (0x00020000) - vop_read is MPSAFE
- `MNTK_WR_MPSAFE` (0x00040000) - vop_write is MPSAFE
- `MNTK_GA_MPSAFE` (0x00080000) - vop_getattr is MPSAFE
- `MNTK_IN_MPSAFE` (0x00100000) - vop_inactive is MPSAFE
- `MNTK_SG_MPSAFE` (0x00200000) - vop_strategy is MPSAFE
- `MNTK_ST_MPSAFE` (0x80000000) - vfs_start is MPSAFE

**Other:**
- `MNTK_WANTRDWR` (0x04000000) - Upgrade to read/write requested
- `MNTK_NOSTKMNT` (0x10000000) - No stacked mounts allowed
- `MNTK_NCALIASED` (0x00800000) - Namecache is aliased
- `MNTK_NOMSYNC` (0x20000000) - Used by tmpfs
- `MNTK_THR_SYNC` (0x40000000) - FS sync thread requested

## Mount Point Lifecycle

### Initialization

**vfs_mount_init()** (vfs_mount.c:154)

Called from `vfsinit()` during system initialization:

```c
void vfs_mount_init(void)
{
    lwkt_token_init(&mountlist_token, "mntlist");
    lwkt_token_init(&mntid_token, "mntid");
    TAILQ_INIT(&mountscan_list);
    mount_init(&dummymount, NULL);
    dummymount.mnt_flag |= MNT_RDONLY;
    dummymount.mnt_kern_flag |= MNTK_ALL_MPSAFE;
}
```

Creates a dummy mount used for vnodes that have no filesystem (e.g., early boot devices).

**mount_init()** (vfs_mount.c:373)

Initializes a mount structure:

```c
void mount_init(struct mount *mp, struct vfsops *ops)
{
    lockinit(&mp->mnt_lock, "vfslock", hz*5, 0);
    lockinit(&mp->mnt_renlock, "renamlk", hz*5, 0);
    lwkt_token_init(&mp->mnt_token, "permnt");
    
    TAILQ_INIT(&mp->mnt_vnodescan_list);
    TAILQ_INIT(&mp->mnt_nvnodelist);
    TAILQ_INIT(&mp->mnt_reservedvnlist);
    TAILQ_INIT(&mp->mnt_jlist);
    
    mp->mnt_nvnodelistsize = 0;
    mp->mnt_flag = 0;
    mp->mnt_hold = 1;  /* hold for umount last drop */
    mp->mnt_iosize_max = MAXPHYS;
    mp->mnt_op = ops;
    
    if (ops == NULL || (ops->vfs_flags & VFSOPSF_NOSYNCERTHR) == 0)
        vn_syncer_thr_create(mp);  /* create syncer thread */
}
```

### Reference Counting

Mount structures use two reference counters:

**mnt_refs** - nchandle references:
- Incremented when nchandles reference this mount
- Managed automatically by the namecache system
- Must reach 1 (only mnt_ncmountpt reference) before unmount

**mnt_hold** - Hold count:
- Prevents premature kfree of the mount structure
- Initialized to 1 in mount_init()
- Used when mount might be accessed without holding mountlist_token

**mount_hold()** / **mount_drop()** (vfs_mount.c:393, 399):

```c
void mount_hold(struct mount *mp)
{
    atomic_add_int(&mp->mnt_hold, 1);
}

void mount_drop(struct mount *mp)
{
    if (atomic_fetchadd_int(&mp->mnt_hold, -1) == 1) {
        KKASSERT(mp->mnt_refs == 0);
        kfree(mp, M_MOUNT);
    }
}
```

### Filesystem ID (FSID) Management

**vfs_getnewfsid()** (vfs_mount.c:441)

Generates a unique filesystem identifier based on the mount path:

```c
void vfs_getnewfsid(struct mount *mp)
{
    fsid_t tfsid;
    int mtype;
    char *retbuf, *freebuf;
    
    mtype = mp->mnt_vfc->vfc_typenum;
    tfsid.val[1] = mtype;
    
    /* Hash the mount point path to create unique FSID */
    error = cache_fullpath(NULL, &mp->mnt_ncmounton, NULL,
                          &retbuf, &freebuf, 0);
    if (error) {
        tfsid.val[0] = makeudev(255, 0);
    } else {
        tfsid.val[0] = makeudev(255,
                               iscsi_crc32(retbuf, strlen(retbuf)) &
                               ~makeudev(255, 0));
        kfree(freebuf, M_TEMP);
    }
    
    mp->mnt_stat.f_fsid.val[0] = tfsid.val[0];
    mp->mnt_stat.f_fsid.val[1] = tfsid.val[1];
}
```

The FSID will be adjusted automatically during `mountlist_insert()` if collisions occur.

## Mount Lists and Trees

### Global Mount Data Structures

**mountlist** (vfs_mount.c:143) - Ordered list of all mounts:
```c
struct mntlist mountlist = TAILQ_HEAD_INITIALIZER(mountlist);
```

**mounttree** (vfs_mount.c:144) - Red-black tree indexed by FSID:
```c
struct mount_rb_tree mounttree = RB_INITIALIZER(dev_tree_mounttree);
```

**mountlist_token** (vfs_mount.c:146) - Protects both structures

### Mount List Operations

**mountlist_insert()** (vfs_mount.c:590)

Adds a mount to the global mount list and tree:

```c
void mountlist_insert(struct mount *mp, int how)
{
    int lim = 0x01000000;
    
    lwkt_gettoken(&mountlist_token);
    
    /* Add to ordered list */
    if (how == MNTINS_FIRST)
        TAILQ_INSERT_HEAD(&mountlist, mp, mnt_list);
    else
        TAILQ_INSERT_TAIL(&mountlist, mp, mnt_list);
    
    /* Add to RB-tree, adjusting FSID on collision */
    while (mount_rb_tree_RB_INSERT(&mounttree, mp)) {
        int32_t val = mp->mnt_stat.f_fsid.val[0];
        val = ((val & 0xFFFF0000) >> 8) | (val & 0x000000FF);
        ++val;
        val = ((val << 8) & 0xFFFF0000) | (val & 0x000000FF);
        mp->mnt_stat.f_fsid.val[0] = val;
        
        if (--lim == 0) {
            lim = 0x01000000;
            mp->mnt_stat.f_fsid.val[1] += 0x0100;
            kprintf("mountlist_insert: fsid collision, "
                   "too many mounts\n");
        }
    }
    
    lwkt_reltoken(&mountlist_token);
}
```

**mountlist_remove()** (vfs_mount.c:663)

Removes a mount from both structures:

```c
void mountlist_remove(struct mount *mp)
{
    struct mountscan_info *msi;
    
    lwkt_gettoken(&mountlist_token);
    
    /* Adjust any active scans past this mount */
    TAILQ_FOREACH(msi, &mountscan_list, msi_entry) {
        if (msi->msi_node == mp) {
            if (msi->msi_how & MNTSCAN_FORWARD)
                msi->msi_node = TAILQ_NEXT(mp, mnt_list);
            else
                msi->msi_node = TAILQ_PREV(mp, mntlist, mnt_list);
        }
    }
    
    TAILQ_REMOVE(&mountlist, mp, mnt_list);
    mount_rb_tree_RB_REMOVE(&mounttree, mp);
    
    lwkt_reltoken(&mountlist_token);
}
```

**vfs_getvfs()** (vfs_mount.c:414)

Looks up a mount by FSID:

```c
struct mount *vfs_getvfs(fsid_t *fsid)
{
    struct mount *mp;
    
    lwkt_gettoken_shared(&mountlist_token);
    mp = mount_rb_tree_RB_LOOKUP_FSID(&mounttree, fsid);
    if (mp)
        mount_hold(mp);  /* caller must mount_drop() */
    lwkt_reltoken(&mountlist_token);
    
    return (mp);
}
```

### Scanning the Mount List

**mountlist_scan()** (vfs_mount.c:736)

Safely iterates over all mounts with a callback:

```c
int mountlist_scan(int (*callback)(struct mount *, void *),
                   void *data, int how)
```

**Scan flags:**
- `MNTSCAN_FORWARD` - Forward iteration
- `MNTSCAN_REVERSE` - Reverse iteration
- `MNTSCAN_NOBUSY` - Don't call vfs_busy() before callback
- `MNTSCAN_NOUNLOCK` - Keep mountlist_token held during callback

The scanner:
1. Registers scan state with mountscan_list
2. Iterates mount list calling callback for each mount
3. Calls vfs_busy() unless MNTSCAN_NOBUSY is set
4. Unlocks mountlist_token during callback (unless MNTSCAN_NOUNLOCK)
5. Handles mount removal during iteration
6. Aggregates callback return values

**Example usage (sys_sync):**
```c
int sys_sync(struct sysmsg *sysmsg, const struct sync_args *uap)
{
    mountlist_scan(sync_callback, NULL, MNTSCAN_FORWARD);
    return (0);
}
```

## Mount Busy Protocol

### vfs_busy() / vfs_unbusy()

The busy protocol prevents a mount from being unmounted while operations are in progress.

**vfs_busy()** (vfs_mount.c:271)

Acquires a shared lock on the mount, incrementing mnt_refs:

```c
int vfs_busy(struct mount *mp, int flags)
{
    atomic_add_int(&mp->mnt_refs, 1);
    lwkt_gettoken(&mp->mnt_token);
    
    /* Check if unmount is in progress */
    if (mp->mnt_kern_flag & MNTK_UNMOUNT) {
        if (flags & LK_NOWAIT) {
            lwkt_reltoken(&mp->mnt_token);
            atomic_add_int(&mp->mnt_refs, -1);
            return (ENOENT);
        }
        /* Wait for unmount to complete */
        mp->mnt_kern_flag |= MNTK_MWAIT;
        tsleep((caddr_t)mp, 0, "vfs_busy", 0);
        lwkt_reltoken(&mp->mnt_token);
        atomic_add_int(&mp->mnt_refs, -1);
        return (ENOENT);
    }
    
    /* Acquire shared lock */
    if (lockmgr(&mp->mnt_lock, LK_SHARED))
        panic("vfs_busy: unexpected lock failure");
    
    lwkt_reltoken(&mp->mnt_token);
    return (0);
}
```

**vfs_unbusy()** (vfs_mount.c:317)

Releases the busy lock:

```c
void vfs_unbusy(struct mount *mp)
{
    mount_hold(mp);  /* prevent race with final unmount */
    atomic_add_int(&mp->mnt_refs, -1);
    lockmgr(&mp->mnt_lock, LK_RELEASE);
    mount_drop(mp);
}
```

## Vnode-Mount Integration

### Associating Vnodes with Mounts

**insmntque()** (vfs_mount.c:835)

Moves a vnode to a mount's vnode list:

```c
void insmntque(struct vnode *vp, struct mount *mp)
{
    struct mount *omp;
    
    /* Remove from old mount if present */
    if ((omp = vp->v_mount) != NULL) {
        lwkt_gettoken(&omp->mnt_token);
        vremovevnodemnt(vp);
        omp->mnt_nvnodelistsize--;
        lwkt_reltoken(&omp->mnt_token);
    }
    
    if (mp == NULL) {
        vp->v_mount = NULL;
        return;
    }
    
    /* Insert into new mount's vnode list */
    lwkt_gettoken(&mp->mnt_token);
    vp->v_mount = mp;
    
    /* Insert before syncer vnode if present, else at tail */
    if (mp->mnt_syncer) {
        TAILQ_INSERT_BEFORE(mp->mnt_syncer, vp, v_nmntvnodes);
    } else {
        TAILQ_INSERT_TAIL(&mp->mnt_nvnodelist, vp, v_nmntvnodes);
    }
    
    mp->mnt_nvnodelistsize++;
    lwkt_reltoken(&mp->mnt_token);
}
```

**getnewvnode()** (vfs_mount.c:194)

Allocates a new vnode and associates it with a mount:

```c
int getnewvnode(enum vtagtype tag, struct mount *mp,
                struct vnode **vpp, int lktimeout, int lkflags)
{
    struct vnode *vp;
    
    KKASSERT(mp != NULL);
    
    vp = allocvnode(lktimeout, lkflags);
    vp->v_tag = tag;
    vp->v_data = NULL;
    
    /* Assign mount's normal operations vector */
    vp->v_ops = &mp->mnt_vn_use_ops;
    vp->v_pbuf_count = nswbuf_kva / NSWBUF_SPLIT;
    
    /* Make vnode visible on mount */
    insmntque(vp, mp);
    
    *vpp = vp;  /* VX locked & refd */
    return (0);
}
```

### Scanning Mount Vnodes

**vmntvnodescan()** (vfs_mount.c:894)

Scans vnodes on a mount point with fast and slow callbacks:

```c
int vmntvnodescan(struct mount *mp, int flags,
                  int (*fastfunc)(...),
                  int (*slowfunc)(...),
                  void *data)
```

**Flags:**
- `VMSC_GETVP` - Lock vnode with vget() before slowfunc
- `VMSC_GETVX` - Lock vnode with vx_get() before slowfunc
- `VMSC_NOWAIT` - Use LK_NOWAIT when locking
- `VMSC_ONEPASS` - Stop after one pass through list

**Callback semantics:**
- `fastfunc()`: Called with only mnt_token held, vnode not locked
  - Return < 0: Skip slowfunc, continue
  - Return 0: Call slowfunc
  - Return > 0: Terminate scan
  
- `slowfunc()`: Called with vnode locked
  - Return 0: Continue
  - Return != 0: Terminate scan

Used by vflush(), filesystem sync operations, and vnode reclamation.

## Mounting a Filesystem

### The sys_mount() System Call

**sys_mount()** (vfs_syscalls.c:118)

Main entry point for the mount(2) system call:

```c
int sys_mount(struct sysmsg *sysmsg, const struct mount_args *uap)
{
    /* uap->type:  filesystem type name */
    /* uap->path:  mount point path */
    /* uap->flags: mount flags */
    /* uap->data:  filesystem-specific data */
}
```

**Mount workflow:**

1. **Permission and type checks** (lines 136-156):
   - Deny user mounts inside jails
   - Copy in filesystem type name
   - Check capabilities (get_fscap)
   - Enforce MNT_NOSUID|MNT_NODEV for non-root

2. **Path lookup** (lines 174-207):
   - Use nlookup() to resolve mount point path
   - Extract nchandle and vnode
   - Check if already mounted (cache_findmount)

3. **Update vs. new mount** (lines 223-279):
   - For MNT_UPDATE: verify VROOT|VPFSROOT, check ownership
   - For new mount: check ownership, validate directory

4. **Find or load VFS** (lines 309-339):
   - Look up vfsconf by name
   - Auto-load kernel module if not found (root only)

5. **Allocate mount structure** (lines 350-361):
   - Allocate and initialize struct mount
   - Call mount_init()
   - Set initial flags from vfsconf

6. **Call VFS_MOUNT** (lines 395-412):
   - For update: call with MNT_UPDATE flag
   - For new: call to initialize filesystem

7. **Finalize mount** (lines 426-451):
   - Create mnt_ncmountpt if needed
   - Mark directory as mount point (NCF_ISMOUNTPT)
   - Insert into mountlist
   - Update process directories (checkdirs)
   - Allocate syncer vnode
   - Call VFS_START()

8. **Error handling** (lines 452-470):
   - On failure: stop syncer, free mount structure
   - Clean up nchandles and vnode

### Mount Point Namecache Integration

Two nchandles connect a mount to the namecache:

**mnt_ncmounton** - The directory being mounted on:
- Set to the mount point directory
- Used to navigate "up" from the filesystem

**mnt_ncmountpt** - The root of the mounted filesystem:
- Created with cache_allocroot() during mount
- Marked with NCF_ISMOUNTPT flag
- Used to navigate "down" into the filesystem

**checkdirs()** (vfs_syscalls.c:494)

After mounting, updates process current/root directories:

```c
static void checkdirs(struct nchandle *old_nch,
                      struct nchandle *new_nch)
{
    struct vnode *olddp = old_nch->ncp->nc_vp;
    struct vnode *newdp;
    struct mount *mp = new_nch->mount;
    
    /* Skip if no processes reference the old vnode */
    if (olddp == NULL || VREFCNT(olddp) == 1)
        return;
    
    /* Resolve new mount's root vnode */
    VFS_ROOT(mp, &newdp);
    cache_setvp(new_nch, newdp);
    
    /* Update rootvnode if mounting over root */
    if (rootvnode == olddp) {
        vref(newdp);
        vfs_cache_setroot(newdp, cache_hold(new_nch));
    }
    
    /* Scan all processes, updating fd_ncdir/fd_nrdir */
    allproc_scan(checkdirs_callback, &info, 0);
    
    vput(newdp);
}
```

### Filesystem-Specific Mount Data

VFS calls **VFS_MOUNT()** to let the filesystem:
1. Parse filesystem-specific mount options from uap->data
2. Read filesystem superblock/metadata
3. Initialize mp->mnt_data with private data
4. Set mp->mnt_stat fields (f_bsize, f_blocks, etc.)
5. Optionally create root vnode

**Example (from a typical VFS_MOUNT):**
```c
static int myfs_mount(struct mount *mp, char *path,
                      caddr_t data, struct ucred *cred)
{
    struct myfs_mount *mmp;
    struct vnode *devvp;
    int error;
    
    /* Parse mount options */
    error = myfs_parse_opts(data, &opts);
    
    /* Open device */
    error = nlookup_init(&nd, opts.fspec, ...);
    devvp = nd.nl_nch.ncp->nc_vp;
    
    /* Read superblock */
    error = myfs_read_super(devvp, &sb);
    
    /* Allocate private mount data */
    mmp = kmalloc(sizeof(*mmp), M_MYFS, M_WAITOK | M_ZERO);
    mmp->devvp = devvp;
    mp->mnt_data = (qaddr_t)mmp;
    
    /* Fill in mount stats */
    mp->mnt_stat.f_bsize = sb.s_blocksize;
    mp->mnt_stat.f_blocks = sb.s_blocks;
    mp->mnt_stat.f_bfree = sb.s_free_blocks;
    
    /* Set max symlink length */
    mp->mnt_maxsymlinklen = sb.s_symlink_max;
    
    vfs_getnewfsid(mp);  /* generate unique FSID */
    return (0);
}
```

## Unmounting a Filesystem

### The sys_unmount() System Call

**sys_unmount()** (vfs_syscalls.c:610)

Entry point for umount(2):

```c
int sys_unmount(struct sysmsg *sysmsg,
                const struct unmount_args *uap)
{
    /* uap->path:  mount point path */
    /* uap->flags: MNT_FORCE, etc. */
}
```

**Unmount workflow:**

1. **Permission checks** (lines 625-657):
   - Deny user unmounts in jails
   - Resolve path with nlookup()
   - Check filesystem type capabilities
   - Verify ownership or root privilege

2. **Validation** (lines 660-682):
   - Reject unmounting root filesystem
   - Verify unmounting at mount point root
   - Check jail ownership

3. **Call dounmount()** (lines 690-694):
   - Hold mount to prevent races
   - Release nlookup resources
   - Perform actual unmount

### The dounmount() Function

**dounmount()** (vfs_syscalls.c:793)

The core unmount implementation:

```c
int dounmount(struct mount *mp, int flags, int halting)
```

**Unmount phases:**

**1. Interlock and lock** (lines 806-842):
```c
/* Check for quickhalt (devfs, tmpfs, procfs on shutdown) */
if (halting && (mp->mnt_kern_flag & MNTK_QUICKHALT))
    quickhalt = 1;

/* Set MNTK_UNMOUNT flag atomically */
mountlist_interlock(dounmount_interlock, mp);

/* Set MNTK_UNMOUNTF if forced */
if (flags & MNT_FORCE)
    mp->mnt_kern_flag |= MNTK_UNMOUNTF;

/* Acquire exclusive mount lock */
lflags = LK_EXCLUSIVE | ((flags & MNT_FORCE) ? 0 : LK_TIMELOCK);
error = lockmgr(&mp->mnt_lock, lflags);
```

**2. Sync and stop syncer** (lines 847-871):
```c
/* Sync dirty data */
vfs_msync(mp, MNT_WAIT);
mp->mnt_flag &= ~MNT_ASYNC;

/* Stop syncer vnode */
if ((vp = mp->mnt_syncer) != NULL) {
    mp->mnt_syncer = NULL;
    vrele(vp);
}

/* Final sync (unless quickhalt) */
if (quickhalt == 0) {
    if ((mp->mnt_flag & MNT_RDONLY) == 0)
        VFS_SYNC(mp, MNT_WAIT);
}
```

**3. Wait for references to drain** (lines 880-955):
```c
for (retry = 0; retry < UMOUNTF_RETRIES; ++retry) {
    /* Invalidate namecache under mount point */
    if ((mp->mnt_kern_flag & MNTK_NCALIASED) == 0) {
        cache_inval(&mp->mnt_ncmountpt,
                   CINV_DESTROY | CINV_CHILDREN);
    }
    
    /* Clear per-CPU caches */
    cache_unmounting(mp);
    if (mp->mnt_refs != 1)
        cache_clearmntcache(mp);
    
    /* Check if ready to unmount */
    ncp = mp->mnt_ncmountpt.ncp;
    if (mp->mnt_refs == 1 &&
        (ncp == NULL || (ncp->nc_refs == 1 &&
                        TAILQ_FIRST(&ncp->nc_list) == NULL))) {
        break;  /* Success! */
    }
    
    /* Force unmount: kill processes using the mount */
    if (flags & MNT_FORCE) {
        switch(retry) {
        case 3:  info.sig = SIGINT;  break;
        case 7:  info.sig = SIGKILL; break;
        default: info.sig = 0;       break;
        }
        allproc_scan(&unmount_allproc_cb, &info, 0);
    }
    
    /* Sleep and retry */
    tsleep(&dummy, 0, "mntbsy", hz / 4 + 1);
}
```

The retry loop:
- Invalidates the namecache tree under the mount
- Clears per-CPU namecache entries
- Checks if mnt_refs dropped to 1 (only mnt_ncmountpt left)
- For forced unmount: sends SIGINT (retry 3) then SIGKILL (retry 7) to processes
- Retries up to 50 times (12.5 seconds)

**4. Call VFS_UNMOUNT** (lines 990-1007):
```c
if (error == 0 && quickhalt == 0) {
    if (mp->mnt_flag & MNT_RDONLY) {
        error = VFS_UNMOUNT(mp, flags);
    } else {
        error = VFS_SYNC(mp, MNT_WAIT);
        if (error == 0 || error == EOPNOTSUPP ||
            (flags & MNT_FORCE)) {
            error = VFS_UNMOUNT(mp, flags);
        }
    }
}
```

**5. Handle errors or finalize** (lines 1010-1120):

On error:
```c
if (error) {
    /* Re-allocate syncer if needed */
    if (mp->mnt_syncer == NULL && hadsyncer)
        vfs_allocate_syncvnode(mp);
    
    /* Clear unmount flags */
    mp->mnt_kern_flag &= ~(MNTK_UNMOUNT | MNTK_UNMOUNTF);
    mp->mnt_flag |= async_flag;
    
    /* Release lock and wakeup waiters */
    lockmgr(&mp->mnt_lock, LK_RELEASE);
    if (mp->mnt_kern_flag & MNTK_MWAIT)
        wakeup(mp);
    
    goto out;
}
```

On success:
```c
/* Remove journals */
journal_remove_all_journals(mp, ...);

/* Remove from mountlist */
mountlist_remove(mp);

/* Remove vnode ops (unless quickhalt) */
if (quickhalt == 0) {
    vfs_rm_vnodeops(mp, NULL, &mp->mnt_vn_coherency_ops);
    vfs_rm_vnodeops(mp, NULL, &mp->mnt_vn_journal_ops);
    vfs_rm_vnodeops(mp, NULL, &mp->mnt_vn_norm_ops);
    vfs_rm_vnodeops(mp, NULL, &mp->mnt_vn_spec_ops);
    vfs_rm_vnodeops(mp, NULL, &mp->mnt_vn_fifo_ops);
}

/* Drop nchandle references */
if (mp->mnt_ncmountpt.ncp != NULL) {
    nch = mp->mnt_ncmountpt;
    cache_zero(&mp->mnt_ncmountpt);
    cache_clrmountpt(&nch);
    cache_drop(&nch);
}
if (mp->mnt_ncmounton.ncp != NULL) {
    nch = mp->mnt_ncmounton;
    cache_zero(&mp->mnt_ncmounton);
    cache_clrmountpt(&nch);
    cache_drop(&nch);
}

/* Release credentials */
if (mp->mnt_cred) {
    crfree(mp->mnt_cred);
    mp->mnt_cred = NULL;
}

/* Decrement vfsconf refcount */
mp->mnt_vfc->vfc_refcount--;

/* Verify no vnodes remain (unless quickhalt) */
if (quickhalt == 0 && !TAILQ_EMPTY(&mp->mnt_nvnodelist))
    panic("unmount: dangling vnode");

/* Release lock */
lockmgr(&mp->mnt_lock, LK_RELEASE);

/* Free mount structure if freeok */
if (freeok) {
    /* Wait for mnt_refs to drop to 0 */
    while (mp->mnt_refs > 0) {
        cache_clearmntcache(mp);
        tsleep(&mp->mnt_refs, 0, "umntrwait", hz / 10 + 1);
    }
    mount_drop(mp);  /* Final free */
}
```

### Forced Unmount

When `MNT_FORCE` is specified:

1. **MNTK_UNMOUNTF flag** alerts filesystem of forced unmount
2. **Process termination**: Processes using the mount are killed:
   - Retry 3: Send SIGINT
   - Retry 7: Send SIGKILL
   - Checks: p_textnch, fd_ncdir, fd_nrdir, fd_njdir, open files
3. **Ignore busy errors**: Unmount proceeds even if refs remain
4. **vflush FORCECLOSE**: Vnodes are forcibly reclaimed

**unmount_allproc_cb()** (vfs_syscalls.c:761):
```c
static int unmount_allproc_cb(struct proc *p, void *arg)
{
    struct unmount_allproc_info *info = arg;
    struct mount *mp = info->mp;
    
    /* Drop text reference */
    if (p->p_textnch.mount == mp)
        cache_drop(&p->p_textnch);
    
    /* Signal if using mount */
    if (info->sig && process_uses_mount(p, mp)) {
        p->p_flags |= P_MUSTKILL;
        ksignal(p, info->sig);
    }
    
    return 0;
}
```

### vflush() - Flushing Mount Vnodes

**vflush()** (vfs_mount.c:1070)

Removes vnodes from a mount during unmount:

```c
int vflush(struct mount *mp, int rootrefs, int flags)
{
    /* flags:
     *   FORCECLOSE - forcibly close active vnodes
     *   WRITECLOSE - close vnodes open for writing
     *   SKIPSYSTEM - skip VSYSTEM vnodes
     */
}
```

Uses vmntvnodescan() to iterate vnodes:

**vflush_scan()** (vfs_mount.c:1124):
```c
static int vflush_scan(struct mount *mp, struct vnode *vp,
                       void *data)
{
    struct vflush_info *info = data;
    int flags = info->flags;
    
    /* Mark for finalization */
    atomic_set_int(&vp->v_refcnt, VREF_FINALIZE);
    
    /* Skip VSYSTEM vnodes if requested */
    if ((flags & SKIPSYSTEM) && (vp->v_flag & VSYSTEM))
        return (0);
    
    /* Don't force-close VCHR/VBLK */
    if (vp->v_type == VCHR || vp->v_type == VBLK)
        flags &= ~(WRITECLOSE | FORCECLOSE);
    
    /* WRITECLOSE: only flush writable regular files */
    if ((flags & WRITECLOSE) && ...) {
        return (0);
    }
    
    /* If only holder, reclaim vnode */
    if (VREFCNT(vp) <= 1) {
        vgone_vxlocked(vp);
        return (0);
    }
    
    /* FORCECLOSE: forcibly destroy vnode */
    if (flags & FORCECLOSE) {
        vhold(vp);
        vgone_vxlocked(vp);
        if (vp->v_mount == NULL)
            insmntque(vp, &dummymount);  /* orphan vnode */
        vdrop(vp);
        return (0);
    }
    
    /* Vnode is busy */
    ++info->busy;
    return (0);
}
```

## Bio Operations Integration

### struct bio_ops

Mount points can register bio_ops for buffer I/O interception (used by HAMMER, soft updates):

```c
struct bio_ops {
    TAILQ_ENTRY(bio_ops) entry;
    void (*io_start)(struct buf *);         /* I/O initiated */
    void (*io_complete)(struct buf *);      /* I/O completed */
    void (*io_deallocate)(struct buf *);    /* buffer freed */
    int  (*io_fsync)(struct vnode *);       /* fsync vnode */
    int  (*io_sync)(struct mount *);        /* sync filesystem */
    void (*io_movedeps)(struct buf *, struct buf *);  /* move deps */
    int  (*io_countdeps)(struct buf *, int); /* count deps */
    int  (*io_checkread)(struct buf *);     /* check read */
    int  (*io_checkwrite)(struct buf *);    /* check write */
};
```

**add_bio_ops()** / **rem_bio_ops()** (vfs_mount.c:1199, 1205):

```c
void add_bio_ops(struct bio_ops *ops)
{
    TAILQ_INSERT_TAIL(&bio_ops_list, ops, entry);
}

void rem_bio_ops(struct bio_ops *ops)
{
    TAILQ_REMOVE(&bio_ops_list, ops, entry);
}
```

**bio_ops_sync()** (vfs_mount.c:1218):

Called during sync operations:

```c
void bio_ops_sync(struct mount *mp)
{
    struct bio_ops *ops;
    
    if (mp) {
        /* Sync specific mount */
        if ((ops = mp->mnt_bioops) != NULL)
            ops->io_sync(mp);
    } else {
        /* Sync all registered bio_ops */
        TAILQ_FOREACH(ops, &bio_ops_list, entry) {
            ops->io_sync(NULL);
        }
    }
}
```

## Root Filesystem Mounting

### vfs_rootmountalloc()

**vfs_rootmountalloc()** (vfs_mount.c:332)

Allocates a mount structure for the root filesystem:

```c
int vfs_rootmountalloc(char *fstypename, char *devname,
                       struct mount **mpp)
{
    struct vfsconf *vfsp;
    struct mount *mp;
    
    /* Find filesystem type */
    vfsp = vfsconf_find_by_name(fstypename);
    if (vfsp == NULL)
        return (ENODEV);
    
    /* Allocate and initialize mount */
    mp = kmalloc(sizeof(struct mount), M_MOUNT,
                 M_WAITOK | M_ZERO);
    mount_init(mp, vfsp->vfc_vfsops);
    lockinit(&mp->mnt_lock, "vfslock", VLKTIMEOUT, 0);
    lockinit(&mp->mnt_renlock, "renamlk", VLKTIMEOUT, 0);
    
    /* Mark as busy */
    vfs_busy(mp, 0);
    
    /* Set initial state */
    mp->mnt_vfc = vfsp;
    mp->mnt_pbuf_count = nswbuf_kva / NSWBUF_SPLIT;
    vfsp->vfc_refcount++;
    mp->mnt_stat.f_type = vfsp->vfc_typenum;
    mp->mnt_flag |= MNT_RDONLY;
    mp->mnt_flag |= vfsp->vfc_flags & MNT_VISFLAGMASK;
    
    /* Set names */
    strncpy(mp->mnt_stat.f_fstypename, vfsp->vfc_name,
            MFSNAMELEN);
    copystr(devname, mp->mnt_stat.f_mntfromname,
            MNAMELEN - 1, 0);
    
    /* Pre-set MPSAFE flags */
    if (vfsp->vfc_flags & VFCF_MPSAFE)
        mp->mnt_kern_flag |= MNTK_ALL_MPSAFE;
    
    *mpp = mp;
    return (0);
}
```

Called early in kernel initialization before the full VFS is available.

## Summary

### Key Takeaways

1. **Mount lifecycle**: init → busy → insert → operate → unmount → free
2. **Two reference counters**: mnt_refs (nchandle) and mnt_hold (kfree prevention)
3. **Two nchandles**: mnt_ncmounton (mounting on) and mnt_ncmountpt (root of fs)
4. **Busy protocol**: vfs_busy/unbusy prevents unmount during operations
5. **Mount lists**: mountlist (ordered) and mounttree (RB-tree by FSID)
6. **Safe iteration**: mountlist_scan() and vmntvnodescan() handle concurrent modifications
7. **Forced unmount**: SIGINT → SIGKILL for processes, FORCECLOSE for vnodes
8. **FSID generation**: Based on mount path hash, auto-adjusted on collision
9. **Syncer integration**: Each mount has a syncer vnode for dirty data tracking
10. **Bio ops**: Extensible buffer I/O hooks for soft updates, journaling

### Important Invariants

- Mount on mountlist ⇔ visible to lookups
- MNTK_UNMOUNT set ⇔ vfs_busy() will fail
- mnt_refs == 1 at unmount ⇔ only mnt_ncmountpt reference remains
- mnt_lock exclusive ⇔ unmounting or updating
- mnt_lock shared ⇔ normal operations (via vfs_busy)

### Common Pitfalls

1. **Forgetting vfs_unbusy()**: Prevents unmounting
2. **Not checking MNTK_UNMOUNT**: Can race with unmount
3. **Holding mnt_token too long**: Blocks all mount operations
4. **Not using mount_hold/drop**: Can cause use-after-free
5. **Modifying mount without mnt_token**: Race conditions

### Related Documentation

- [VFS Name Lookup and Caching](namecache.md) - Namecache integration
- [VFS Initialization](index.md) - System initialization
- [VFS Vnodes](../../../kern/vfs/index.md) - Vnode lifecycle

### Source Code Locations

- `sys/kern/vfs_mount.c` - Mount point management
- `sys/kern/vfs_syscalls.c:118` - sys_mount()
- `sys/kern/vfs_syscalls.c:610` - sys_unmount()
- `sys/kern/vfs_syscalls.c:793` - dounmount()
- `sys/sys/mount.h:216` - struct mount definition
- `sys/sys/mount.h:274` - Mount flags (MNT_*)
- `sys/sys/mount.h:348` - Kernel flags (MNTK_*)
