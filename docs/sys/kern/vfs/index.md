# Virtual Filesystem (VFS)

## Overview

The Virtual Filesystem (VFS) layer is DragonFly BSD's abstraction layer that provides a uniform interface between the kernel and concrete filesystem implementations. It allows the kernel to support multiple filesystem types (UFS, HAMMER, HAMMER2, NFS, tmpfs, devfs, etc.) through a common API.

**Architecture:**
- **Vnodes** - In-memory representation of files, directories, devices
- **VFS operations** - Filesystem-level operations (mount, statfs, sync)
- **Vnode operations (VOPs)** - File/directory-level operations (open, read, write, lookup)
- **Name cache** - High-performance path component caching
- **Buffer cache** - Disk block caching and I/O management

**Key source files (Phase 6a - Initialization and Core):**
- `vfs_init.c` (504 lines) — VFS subsystem initialization
- `vfs_conf.c` (713 lines) — Filesystem type registration, root mounting
- `vfs_subr.c` (2,650 lines) — Vnode lifecycle, buffer management utilities
- `vfs_vfsops.c` (321 lines) — VFS operation wrappers (mount, unmount, sync, etc.)
- `vfs_vnops.c` (1,352 lines) — High-level vnode operations (vn_open, vn_close, vn_rdwr)
- `vfs_vopops.c` (2,227 lines) — Vnode operation dispatch layer
- `vfs_default.c` (1,684 lines) — Default vnode operation implementations

---

## VFS Initialization (vfs_init.c)

### Initialization Flow

Called during kernel bootstrap via `SYSINIT(vfs, SI_SUB_VFS, SI_ORDER_FIRST, vfsinit, NULL)`:

```c
vfsinit()
├─ TAILQ_INIT(&vnodeopv_list)           // Initialize vop vector list
├─ namei_oc = objcache_create_simple()  // Create namei path buffer cache
├─ vfs_subr_init()                      // Initialize vnode subsystem
├─ vfs_mount_init()                     // Initialize mount structures
├─ vfs_lock_init()                      // Initialize vnode locking
├─ nchinit()                            // Initialize name cache
└─ vattr_null(&va_null)                 // Initialize null vattr template
```

### Vnode Operations Vector Management

**Key functions:**
- `vfs_add_vnodeops()` - Add/register vnode operations vector
- `vfs_rm_vnodeops()` - Remove vnode operations vector  
- `vfs_calc_vnodeops()` - Fill in NULL entries with defaults

Each filesystem provides a `struct vop_ops` with function pointers for file operations. The VFS layer ensures NULL entries are replaced with default implementations.

### Filesystem Registration (vfsconf)

**Data structures:**

```c
struct vfsconf {
    struct vfsops *vfc_vfsops;       // Filesystem operations
    char          vfc_name[MFSNAMELEN]; // Filesystem type name (e.g., "ufs")
    int           vfc_typenum;       // Unique type number
    int           vfc_refcount;      // Active mount count
    ...
};
```

**Global registry:**
- `vfsconf_list` - STAILQ of all registered filesystem types
- `vfsconf_maxtypenum` - Highest assigned type number

**Key functions (vfs_init.c):**
- `vfs_register(struct vfsconf *)` - Register a filesystem type
  - Assigns unique `vfc_typenum`
  - Fills in default vfsops entries (vfs_root, vfs_statfs, vfs_sync, etc.)
  - Calls filesystem's `vfs_init()` method
  - Registers sysctl nodes under `vfs.<fsname>`
- `vfs_unregister(struct vfsconf *)` - Unregister (checks refcount)
- `vfsconf_find_by_name(const char *)` - Lookup filesystem by name
- `vfsconf_find_by_typenum(int)` - Lookup by type number

**Module integration:**
`vfs_modevent()` handles MOD_LOAD/MOD_UNLOAD for filesystem kernel modules.

---

## Root Filesystem Mounting (vfs_conf.c)

### Boot Sequence

`SYSINIT(mountroot, SI_SUB_MOUNT_ROOT, SI_ORDER_SECOND, vfs_mountroot, NULL)` orchestrates root filesystem mounting:

```c
vfs_mountroot()
├─ sync_devs()                    // Wait for disk device probing
├─ tsleep(..., hz * wakedelay)    // Default 2s delay (vfs.root.wakedelay)
├─ Try boot-time root specifications:
│  ├─ RB_CDROM flag → try cdrom_rootdevnames[] array
│  ├─ ROOTDEVNAME (compile-time)
│  ├─ kgetenv("vfs.root.mountfrom") from loader
│  ├─ rootdevnames[0], rootdevnames[1] (machine-dependent legacy)
│  └─ RB_ASKNAME → vfs_mountroot_ask() (interactive prompt)
└─ Panic if all methods fail
```

**Root mount string format:** `<fstype>:<device>` (e.g., `"hammer2:da0s1a"`, `"ufs:da0s1a"`)

### vfs_mountroot_try()

Attempts to mount a specified root:

1. Parse `<fstype>:<devname>` string
2. Call `vfs_rootmountalloc()` to allocate `struct mount`
3. Set `mp->mnt_flag |= MNT_ROOTFS`
4. Call `VFS_MOUNT(mp, NULL, NULL, cred)`
5. On success:
   - Insert into `mountlist` (first position)
   - Call `inittodr()` to sync system clock from fs timestamp
   - Get root vnode via `VFS_ROOT()`
   - Setup `proc0`'s fd_cdir, fd_rdir, fd_ncdir, fd_nrdir
   - Call `vfs_cache_setroot()` for global rootnch
   - Allocate syncer vnode via `vfs_allocate_syncvnode()`
   - Call `VFS_START(mp, 0)`

### Interactive Root Prompt

`vfs_mountroot_ask()` - when RB_ASKNAME boot flag set:

```
mountroot> ?           # List available disk devices
mountroot> ufs:da0s1a  # Try mount
mountroot> panic       # Panic the kernel
mountroot> abort       # Give up
```

Uses `devfs_scan_callback()` to enumerate disk devices.

### devfs Mounting

`vfs_mountroot_devfs()` - Mounts `/dev` (or `<init_chroot>/dev`):

1. nlookup `/dev` path
2. Allocate mount structure
3. Call `VFS_MOUNT(mp, "/dev", NULL, cred)`
4. Mark ncp with `NCF_ISMOUNTPT`
5. Insert into mountlist

---

## Vnode Lifecycle (vfs_subr.c)

### Vnode Subsystem Initialization

**vfs_subr_init()** (called from vfsinit):

Calculates `maxvnodes` based on available RAM:
- Base formula: `maxvnodes = freemem / (80 * (sizeof(struct vm_object) + sizeof(struct vnode)))`
- Non-linear scaling for systems > 1GB and > 8GB
- Minimum: max(MINVNODES=2000, maxproc * 8)
- Maximum: MAXVNODES=4000000
- Bounded by kernel VA space (KvaSize)

**Global state:**
- `numvnodes` - Current vnode count (sysctl `debug.numvnodes`)
- `maxvnodes` - Maximum vnodes (sysctl `kern.maxvnodes`)
- `spechash_token` - Token protecting device vnode hash

### Vnode Buffer Tree Management

Vnodes maintain red-black trees for buffer management (defined in vfs_subr.c:133):

```c
struct vnode {
    struct buf_rb_tree v_rbclean_tree;  // Clean buffers
    struct buf_rb_tree v_rbdirty_tree;  // Dirty buffers
    struct buf_rb_hash v_rbhash_tree;   // All buffers (hash by b_loffset)
    ...
};
```

**Buffer-vnode association:**
- `bgetvp(struct vnode *, struct buf *)` - Associate buffer with vnode (vfs_subr.c:964)
  - Inserts into `v_rbhash_tree`
  - Diagnostics check for overlapping buffers
- `brelvp(struct buf *)` - Disassociate buffer from vnode

### Buffer Invalidation

**vinvalbuf()** (vfs_subr.c:313) - Flush and invalidate all buffers for a vnode:

```c
vinvalbuf(struct vnode *vp, int flags, int slpflag, int slptimeo)
```

**Flags:**
- `V_SAVE` - Call `VOP_FSYNC()` before invalidating

**Algorithm:**
1. If V_SAVE: wait for write I/O, then `VOP_FSYNC()`
2. Loop:
   - Scan `v_rbclean_tree` and `v_rbdirty_tree` with `vinvalbuf_bp()`
   - Wait for all I/O completion (`bio_track_wait()`)
   - Wait for VM paging I/O
3. Remove VM pages via `vm_object_page_remove()`
4. Panic if any buffers remain

**Used during:**
- Vnode reclamation
- Truncation/unmount operations

### Buffer Truncation

**vtruncbuf()** (vfs_subr.c:475) - Truncate file buffers to new length:

```c
vtruncbuf(struct vnode *vp, off_t length, int blksize)
```

1. Round `length` up to next block boundary
2. Scan clean/dirty trees with `vtruncbuf_bp_trunc_cmp()`
3. Destroy buffers with `b_loffset >= truncloffset`
4. For non-zero truncation: fsync remaining metadata buffers
5. Call `vnode_pager_setsize()` to truncate VM backing store
6. Wait for I/O completion

### Filesystem Sync (vfsync)

**vfsync()** (vfs_subr.c:680) - Sync dirty buffers for a vnode:

```c
vfsync(struct vnode *vp, int waitfor, int passes,
       int (*checkdef)(struct buf *),
       int (*waitoutput)(struct vnode *, struct thread *))
```

**Wait modes:**
- `MNT_LAZY` - Lazy flush (limit to 1MB data), used by syncer
- `MNT_NOWAIT` - Asynchronous flush (one data pass, one metadata pass)
- `MNT_WAIT` - Synchronous (multiple passes until clean)

**Algorithm for MNT_WAIT:**
1. Data-only pass (fast, no waiting)
2. Wait for I/O
3. Full pass (data + metadata)
4. Additional passes (up to `passes` count) until no dirty buffers remain
5. On final pass: set `info.synchronous = 1` to force blocking writes

**Lazy mode** (`MNT_LAZY`):
- Scan from `vp->v_lazyw` offset
- Stop after flushing 1MB (`info.lazylimit`)
- Updates `v_lazyw` to track progress
- Reschedules vnode for syncer if incomplete

**Used by:**
- `VOP_FSYNC()` implementations
- Periodic sync daemon

### Timestamp Precision

**vfs_timestamp()** (vfs_subr.c:238) - Get current timestamp with configurable precision:

**Sysctl `vfs.timestamp_precision`:**
- 0 = Seconds only
- 1 = Microseconds (tick precision, default if hz >= 100)
- 2 = Microseconds (tick precision)
- 3 = Nanoseconds (tick precision)
- 4 = Microseconds (maximum precision, default if hz < 100)
- 5 = Nanoseconds (maximum precision)

---

## VFS Operations (vfs_vfsops.c)

### MPSAFE Wrapper Layer

`vfs_vfsops.c` provides MPSAFE wrappers for all `struct vfsops` methods. Each wrapper:

1. Acquires mount's MP lock (`VFS_MPLOCK(mp)`)
2. Calls filesystem's method via function pointer
3. Releases MP lock (`VFS_MPUNLOCK()`)

**Key wrappers:**

```c
int vfs_mount(struct mount *mp, char *path, caddr_t data, struct ucred *cred)
int vfs_start(struct mount *mp, int flags)
int vfs_unmount(struct mount *mp, int mntflags)
int vfs_root(struct mount *mp, struct vnode **vpp)
int vfs_sync(struct mount *mp, int waitfor)
int vfs_statfs(struct mount *mp, struct statfs *sbp, struct ucred *cred)
int vfs_statvfs(struct mount *mp, struct statvfs *sbp, struct ucred *cred)
int vfs_vget(struct mount *mp, struct vnode *dvp, ino_t ino, struct vnode **vpp)
int vfs_fhtovp(struct mount *mp, struct vnode *rootvp, struct fid *fhp, struct vnode **vpp)
int vfs_vptofh(struct vnode *vp, struct fid *fhp)
int vfs_checkexp(struct mount *mp, struct sockaddr *nam, int *extflagsp, struct ucred **credanonp)
int vfs_extattrctl(struct mount *mp, int cmd, struct vnode *vp, int attrnamespace, 
                   const char *attrname, struct ucred *cred)
```

**Quota integration:**
- `vfs_start()` calls `VFS_ACINIT()` on successful start
- `vfs_unmount()` calls `VFS_ACDONE()` before unmounting

**Mount point locking strategy:**
- Most operations use exclusive MP lock
- Some operations conditionally use MP lock via `VFS_MPLOCK_FLAG()`
- Filesystems can opt-in to MPSAFE via `MNTK_*_MPSAFE` flags

---

## High-Level Vnode Operations (vfs_vnops.c)

### vn_open() - Open/Create Files

**Signature:**

```c
int vn_open(struct nlookupdata *nd, struct file **fpp, int fmode, int cmode)
```

**Purpose:** Unified entry point for opening and creating files/directories.

**Flow:**

```c
vn_open()
├─ Setup nd->nl_flags (NLC_OPEN, NLC_APPEND, NLC_READ, NLC_WRITE, etc.)
├─ if (fmode & O_CREAT):
│  ├─ Set NLC_CREATE, NLC_REFDVP, call nlookup()
│  └─ bwillinode(1)  // Reserve inode space
├─ else:
│  └─ nlookup()  // Normal lookup
├─ Check filesystem modification stall (ncp_writechk())
├─ if (O_CREAT and ncp->nc_vp == NULL):
│  └─ VOP_NCREATE(&nl_nch, nl_dvp, &vp, cred, vap)  // Create new file
├─ else:
│  └─ cache_vget(&nl_nch, cred, LK_EXCLUSIVE/LK_SHARED, &vp)  // Get existing
├─ Validate vnode type (reject VLNK, VSOCK; check O_DIRECTORY)
├─ Check write permission (vn_writechk()) if FWRITE|O_TRUNC
├─ if (O_TRUNC):
│  ├─ VOP_SETATTR_FP(vp, vap->va_size=0, cred, fp)
│  └─ VFS_ACCOUNT()  // Quota adjustment
├─ Setup VNSWAPCACHE flags based on NCF_UF_CACHE/NCF_SF_NOCACHE
├─ if (fp):
│  └─ fp->f_nchandle = nd->nl_nch  // Store namecache handle
├─ VOP_OPEN(vp, fmode, cred, fpp)  // Call filesystem's open method
└─ Return vnode in nd->nl_open_vp (if fp == NULL) or fp->f_data (if fp != NULL)
```

**Key features:**
- **Shared locking optimization:** Uses LK_SHARED for read-only opens (when appropriate)
- **ESTALE handling:** Re-resolves namecache on ESTALE errors
- **Quota integration:** Checks/accounts for size changes on O_TRUNC
- **Swapcache control:** Propagates NCF_UF_CACHE flags to VNSWAPCACHE vnode flag

**Error cases:**
- `EACCES` - Permission denied
- `EEXIST` - O_CREAT | O_EXCL and file exists
- `EISDIR` - Attempting to write/truncate a directory
- `ENOTDIR` - O_DIRECTORY on non-directory
- `EMLINK` - Opened a symlink (shouldn't happen with NLC_FOLLOW)
- `ETXTBSY` - File is executing, cannot write
- `EROFS` - Read-only filesystem
- `ESTALE` - NFS stale file handle (triggers retry)

### vn_close() - Close Files

```c
int vn_close(struct vnode *vp, int flags, struct file *fp)
```

1. Lock vnode (LK_SHARED | LK_RETRY | LK_FAILRECLAIM)
2. Call `VOP_CLOSE(vp, flags, fp)`
3. Unlock vnode

**Flags:**
- `FREAD`, `FWRITE` - Indicating how file was opened
- `FNONBLOCK` - Non-blocking close

### vn_rdwr() - Kernel File I/O

```c
int vn_rdwr(enum uio_rw rw, struct vnode *vp, caddr_t base, int len,
            off_t offset, enum uio_seg segflg, int ioflags,
            struct ucred *cred, int *aresid)
```

**Purpose:** Synchronous read/write from kernel context.

**Used by:**
- Executable loading (imgact_elf.c)
- Core dumps (kern_sig.c)
- Swap pager
- Kernel module loading

**Steps:**
1. Setup struct uio with I/O parameters
2. If UIO_SYSSPACE and vnode has VM object: use `vn_cache_strategy()`
3. Else: call `VOP_READ()` or `VOP_WRITE()`
4. Return residual count in `*aresid`

### vn_writechk() - Write Permission Check

```c
int vn_writechk(struct vnode *vp)
```

**Checks:**
- `VTEXT` flag - File is executing (returns ETXTBSY)
- `MNT_RDONLY` - Filesystem is read-only (returns EROFS)

**Called after vnode is locked.**

### ncp_writechk() - Namecache Write Check

```c
int ncp_writechk(struct nchandle *nch)
```

**Checks:**
- `MNT_RDONLY` - Associated mount is read-only (returns EROFS)
- Calls `VFS_MODIFYING()` if filesystem has special modifying callback

**Called BEFORE vnodes are locked** (allows filesystem to stall modifications).

### File Descriptor Operations

**vnode_fileops** structure (vfs_vnops.c:77) - Provides file operations for vnodes:

```c
struct fileops vnode_fileops = {
    .fo_read     = vn_read,
    .fo_write    = vn_write,
    .fo_ioctl    = vn_ioctl,
    .fo_kqfilter = vn_kqfilter,
    .fo_stat     = vn_statfile,
    .fo_close    = vn_closefile,
    .fo_shutdown = nofo_shutdown,
    .fo_seek     = vn_seek
};
```

These functions bridge between file descriptor operations (`read(2)`, `write(2)`, etc.) and vnode operations (`VOP_READ()`, `VOP_WRITE()`).

**vn_read():**
- Validates file is open for reading
- For VREG: updates `f_offset` optimistically
- Calls `VOP_READ(vp, uio, ioflag, cred, fp)`
- Handles `f_offset` races

**vn_write():**
- Validates file is open for writing
- Handles `IO_APPEND` flag
- Quota checks for regular files
- Calls `VOP_WRITE(vp, uio, ioflag, cred, fp)`
- Quota accounting on success

**vn_ioctl():**
- Validates vnode type (reject directories)
- Calls `VOP_IOCTL(vp, cmd, data, fflag, cred, msg)`

**vn_statfile():**
- Calls `VOP_GETATTR(vp, &vattr)`
- Converts `struct vattr` to `struct stat`
- Fills in st_dev, st_ino, st_mode, st_size, timestamps, etc.

**vn_seek():**
- Validates seek offset (no negative offsets)
- For VREG: allows seeks beyond EOF
- For VDIR: offset must be <= current size

---

## Vnode Operation Dispatch (vfs_vopops.c)

### Purpose

`vfs_vopops.c` provides MPSAFE dispatch wrappers for all vnode operations. Similar to `vfs_vfsops.c` but for per-vnode operations rather than per-mount operations.

### Wrapper Pattern

Each VOP wrapper:

1. Initializes `struct vop_*_args` with operation parameters
2. Sets `a_head.a_desc` (operation descriptor)
3. Sets `a_head.a_ops` (vnode's ops vector)
4. Acquires mount's MP lock (`VFS_MPLOCK(vp->v_mount)`)
5. Calls operation via `DO_OPS(ops, error, &ap, vop_field)`
6. Releases MP lock (`VFS_MPUNLOCK()`)
7. Returns error

**Example - VOP_OPEN():**

```c
int vop_open(struct vop_ops *ops, struct vnode *vp, int mode,
             struct ucred *cred, struct file **fpp)
{
    struct vop_open_args ap;
    VFS_MPLOCK_DECLARE;
    int error;

    // Decrement VAGE0/VAGE1 flags (aging mechanism)
    if (vp->v_flag & VAGE0) {
        vclrflags(vp, VAGE0);
    } else if (vp->v_flag & VAGE1) {
        vclrflags(vp, VAGE1);
        vsetflags(vp, VAGE0);
    }

    ap.a_head.a_desc = &vop_open_desc;
    ap.a_head.a_ops = ops;
    ap.a_vp = vp;
    ap.a_fpp = fpp;
    ap.a_mode = mode;
    ap.a_cred = cred;

    VFS_MPLOCK(vp->v_mount);
    DO_OPS(ops, error, &ap, vop_open);
    VFS_MPUNLOCK();

    return(error);
}
```

### Key Vnode Operations

**Namespace operations (new API):**
- `vop_nresolve()` - Resolve namecache entry to vnode
- `vop_nlookupdotdot()` - Lookup parent directory (..)
- `vop_ncreate()` - Create file via namecache
- `vop_nmkdir()` - Create directory via namecache
- `vop_nmknod()` - Create device node via namecache
- `vop_nlink()` - Create hard link via namecache
- `vop_nsymlink()` - Create symbolic link via namecache
- `vop_nwhiteout()` - Create/delete whiteout entry
- `vop_nremove()` - Remove file via namecache
- `vop_nrmdir()` - Remove directory via namecache
- `vop_nrename()` - Rename file/directory via namecache

**File operations:**
- `vop_open()` - Open file
- `vop_close()` - Close file
- `vop_read()` - Read data
- `vop_write()` - Write data (with quota accounting)
- `vop_ioctl()` - I/O control operations
- `vop_poll()` - Poll for events
- `vop_kqfilter()` - Register kqueue filter
- `vop_fsync()` - Sync dirty data/metadata
- `vop_fdatasync()` - Sync data only

**Metadata operations:**
- `vop_getattr()` - Get vnode attributes
- `vop_getattr_lite()` - Get lightweight attributes
- `vop_setattr()` - Set vnode attributes
- `vop_access()` - Check access permissions

**I/O operations:**
- `vop_bmap()` - Map logical block to physical
- `vop_strategy()` - Perform I/O strategy
- `vop_getpages()` - Get VM pages
- `vop_putpages()` - Flush VM pages

**Directory operations:**
- `vop_readdir()` - Read directory entries
- `vop_readlink()` - Read symbolic link target

**Lifecycle operations:**
- `vop_inactive()` - Vnode is no longer referenced
- `vop_reclaim()` - Reclaim vnode resources

**Special operations:**
- `vop_mmap()` - Memory-map file
- `vop_advlock()` - Advisory locking
- `vop_balloc()` - Allocate blocks
- `vop_freeblks()` - Free blocks (sparse files/truncation)
- `vop_pathconf()` - Get filesystem path configuration
- `vop_markatime()` - Mark access time (deferred atime updates)
- `vop_allocate()` - Preallocate space (fallocate)

**Extended attributes:**
- `vop_getacl()` - Get ACL
- `vop_setacl()` - Set ACL
- `vop_aclcheck()` - Check ACL validity
- `vop_getextattr()` - Get extended attribute
- `vop_setextattr()` - Set extended attribute

### MPSAFE Optimization

Some operations support conditional locking for better concurrency:

**VFS_MPLOCK_FLAG()** variants:
- `MNTK_GA_MPSAFE` - Getattr is MP-safe
- `MNTK_RD_MPSAFE` - Read is MP-safe
- `MNTK_WR_MPSAFE` - Write is MP-safe
- `MNTK_ST_MPSAFE` - Start is MP-safe

If the mount has the appropriate flag set, the wrapper skips MP lock acquisition.

### Quota Integration

**vop_write()** wrapper includes comprehensive quota handling:

1. Before write: `VOP_GETATTR()` to get current size and ownership
2. Calculate potential new size (accounting for IO_APPEND)
3. Check quota: `vq_write_ok(mp, uid, gid, delta)`
4. Perform write via filesystem's method
5. On success: `VFS_ACCOUNT(mp, uid, gid, actual_delta)`

---

## Default Vnode Operations (vfs_default.c)

### Default Operations Table

`default_vnode_vops` provides fallback implementations when filesystems don't implement specific operations:

**Common defaults:**
- `.vop_default = vop_eopnotsupp` - Return EOPNOTSUPP for unimplemented ops
- `.vop_advlock = vop_einval` - Advisory locking not supported
- `.vop_fsync = vop_null` - Successful no-op (for filesystems with no dirty buffers)
- `.vop_fdatasync = vop_stdfdatasync` - Calls vop_fsync
- `.vop_open = vop_stdopen` - Standard open logic
- `.vop_close = vop_stdclose` - Standard close logic
- `.vop_mmap = vop_einval` - Memory-mapping not supported by default
- `.vop_readlink = vop_einval` - Not a symlink
- `.vop_markatime = vop_stdmarkatime` - Standard atime marking

**Compatibility wrappers** (old namespace API → new):
- `.vop_nresolve = vop_compat_nresolve`
- `.vop_ncreate = vop_compat_ncreate`
- `.vop_nmkdir = vop_compat_nmkdir`
- `.vop_nremove = vop_compat_nremove`
- `.vop_nrename = vop_compat_nrename`

These wrappers translate new-style namecache operations (VOPs taking `struct nchandle *`) to old-style operations (VOPs taking `struct componentname *`), allowing legacy filesystems to work with modern code.

### Standard Error Returns

```c
int vop_eopnotsupp(struct vop_generic_args *ap) { return EOPNOTSUPP; }
int vop_ebadf(struct vop_generic_args *ap)      { return EBADF; }
int vop_enotty(struct vop_generic_args *ap)     { return ENOTTY; }
int vop_einval(struct vop_generic_args *ap)     { return EINVAL; }
int vop_null(struct vop_generic_args *ap)       { return 0; }
```

### Standard Implementations

**vop_stdopen():**
- For VCHR (character device): calls `spec_open()`
- For VFIFO: calls `fifo_open()`
- Otherwise: returns 0

**vop_stdclose():**
- For VCHR: calls `spec_close()`
- For VFIFO: calls `fifo_close()`
- Otherwise: returns 0

**vop_stdgetattr_lite():**
- Calls `VOP_GETATTR()` and extracts lightweight fields
- Used for stat-like operations that don't need full vattr

**vop_stdmarkatime():**
- Sets `VN_ATIME` flag on vnode
- Actual atime update deferred until vnode is written back

**vop_stdpathconf():**
- Returns standard POSIX path configuration values
- `_PC_LINK_MAX`, `_PC_NAME_MAX`, `_PC_PATH_MAX`, etc.

**vop_stdallocate():**
- Default fallocate(2) implementation
- Simply extends file size via `VOP_SETATTR()` (non-sparse)

### Compatibility Layer (Old → New Namespace API)

**vop_compat_nresolve():**
Translates `VOP_NRESOLVE(nch, dvp, cred)` to:
1. Extract componentname from nch
2. Call `VOP_OLD_LOOKUP(dvp, &vp, cnp)`
3. Cache result in nch

**vop_compat_ncreate():**
Translates `VOP_NCREATE(nch, dvp, &vp, cred, vap)` to:
1. Lock parent directory exclusively
2. Call `VOP_OLD_CREATE(dvp, &vp, cnp, vap)`
3. Cache new vnode in nch

**vop_compat_nremove():**
Translates `VOP_NREMOVE(nch, dvp, cred)` to:
1. Extract componentname
2. Lock parent and target
3. Call `VOP_OLD_REMOVE(dvp, vp, cnp)`

Similar wrappers exist for nmkdir, nmknod, nlink, nsymlink, nrmdir, nrename, nwhiteout.

**Purpose:** Allows old filesystems (written for the componentname API) to work transparently with the modern namecache-centric API.

---

## Summary: Phase 6a

**Files analyzed (7 files, 9,451 lines):**
1. vfs_init.c (504 lines) - VFS/vfsconf initialization, vnode ops registration
2. vfs_conf.c (713 lines) - Root filesystem mounting, interactive prompt
3. vfs_subr.c (2,650 lines) - Vnode lifecycle, buffer management, sync operations
4. vfs_vfsops.c (321 lines) - MPSAFE VFS operation wrappers
5. vfs_vnops.c (1,352 lines) - High-level vnode operations (vn_open, vn_close, vn_rdwr)
6. vfs_vopops.c (2,227 lines) - Vnode operation dispatch layer
7. vfs_default.c (1,684 lines) - Default VOP implementations, compatibility layer

**Key Concepts:**
- **Vnode** - In-memory file/directory representation
- **VFS operations** - Filesystem-level (mount, statfs, sync)
- **Vnode operations** - File-level (open, read, write, lookup)
- **vfsconf** - Filesystem type registry
- **MPSAFE wrappers** - Per-mount/vnode operation locking
- **Namespace API** - Modern namecache-centric operations (VOP_NRESOLVE, VOP_NCREATE)
- **Compatibility layer** - Old componentname API → new namecache API

**Next Phase 6 Steps:**
- 6b: Name lookup and caching (vfs_cache.c, vfs_nlookup.c)
- 6c: Mounting and syscalls (vfs_mount.c, vfs_syscalls.c)
- 6d: Buffer cache and I/O (vfs_bio.c, vfs_cluster.c)
- 6e: Extensions (locking, journaling, quota, AIO)
