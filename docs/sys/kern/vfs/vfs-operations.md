# VFS Operations Framework

## Overview

The VFS operations framework provides a flexible, extensible architecture for implementing filesystem operations in DragonFly BSD. At its core is the **VOP (Vnode Operation)** dispatch mechanism, which allows different filesystem implementations to provide their own handlers for standard operations like open, read, write, and close.

The framework consists of multiple layers:

1. **VOP Wrapper Layer** (`vfs_vopops.c`) - High-level entry points with locking and journaling
2. **Journaling Layer** (`vfs_journal.c`) - Optional transaction recording
3. **Filesystem Implementation Layer** - Filesystem-specific operation handlers
4. **Compatibility Layer** (`vfs_default.c`) - Default implementations and API translation

This architecture enables:
- Uniform interface across different filesystem types
- Transparent journaling support
- Gradual migration from legacy APIs
- Per-mount locking strategies (MPLOCK vs fine-grained)

**Key files:**
- `sys/kern/vfs_vopops.c` - VOP wrapper functions and dispatch
- `sys/kern/vfs_vnops.c` - High-level vnode operations
- `sys/kern/vfs_default.c` - Default implementations and compatibility
- `sys/sys/vfsops.h` - Operation structures and argument definitions

## VOP Architecture

### Operation Vectors

Every vnode has an associated `vop_ops` structure that defines handlers for filesystem operations:

```c
struct vop_ops {
    struct vop_generic_args **vop_ops_first_p;
    struct vop_generic_args **vop_ops_last_p;
    
    int (*vop_default)(struct vop_generic_args *);
    int (*vop_old_lookup)(struct vop_old_lookup_args *);
    int (*vop_old_create)(struct vop_old_create_args *);
    // ... many more operations
    int (*vop_nresolve)(struct vop_nresolve_args *);
    int (*vop_nlookupdotdot)(struct vop_nlookupdotdot_args *);
    int (*vop_ncreate)(struct vop_ncreate_args *);
    int (*vop_nmkdir)(struct vop_nmkdir_args *);
    // ... etc
};
```

**Key characteristics:**
- Each operation is a function pointer taking a typed argument structure
- The `vop_default` handler catches unimplemented operations
- Two API generations coexist: old (componentname) and new (nchandle)
- Operation vectors are typically defined statically per filesystem type

### Argument Structures

All VOP argument structures inherit from `vop_generic_args`:

```c
struct vop_generic_args {
    struct vop_ops *a_ops;
    int a_reserved[3];
    int a_desc_offset;
};
```

Example operation-specific structures:

```c
struct vop_open_args {
    struct vop_ops *a_ops;
    int a_reserved[3];
    int a_desc_offset;
    struct vnode *a_vp;
    int a_mode;
    struct ucred *a_cred;
    struct file *a_fp;
};

struct vop_read_args {
    struct vop_ops *a_ops;
    int a_reserved[3];
    int a_desc_offset;
    struct vnode *a_vp;
    struct uio *a_uio;
    int a_ioflag;
    struct ucred *a_cred;
};
```

**Important fields:**
- `a_ops` - Points to the operation vector (used for dispatch)
- `a_desc_offset` - Offset within vop_ops to find the correct handler
- Operation-specific arguments follow the header

### Dispatch Mechanism

VOP dispatch follows this path:

1. **Caller** invokes wrapper (e.g., `vop_open()`)
2. **Wrapper** handles MPLOCK if needed, sets up arguments
3. **Journal layer** (if enabled) records operation
4. **Filesystem handler** performs actual operation
5. **Return path** releases locks, cleans up

The actual dispatch uses the `a_desc_offset` to index into the `vop_ops` structure and call the appropriate handler.

## VOP Wrapper Functions

### Purpose and Design

The VOP wrapper functions in `vfs_vopops.c` provide:

1. **MPLOCK handling** - Acquire/release Giant lock for non-MPSAFE filesystems
2. **Argument marshalling** - Set up typed argument structures
3. **Journal integration** - Optional operation recording
4. **Error checking** - Validate return values

### MPLOCK Management

DragonFly supports both traditional (MPLOCK-protected) and modern (fine-grained locking) filesystems. Per-mount flags control locking behavior:

**Mount flags** (from `sys/mount.h`):
- `MNTK_MPSAFE` - Filesystem is fully SMP-safe
- `MNTK_RD_MPSAFE` - Reads are SMP-safe, writes need MPLOCK
- `MNTK_WR_MPSAFE` - Writes are SMP-safe, reads need MPLOCK
- `MNTK_GA_MPSAFE` - Getattr is SMP-safe
- `MNTK_IN_MPSAFE` - Inactive is SMP-safe
- `MNTK_SG_MPSAFE` - Strategy is SMP-safe
- `MNTK_NCALIASED` - Nchandle aliasing enabled

**Macros for MPLOCK handling:**

```c
#define VFS_MPLOCK_FLAG(MP, FLAG) \
    ((MP) == NULL || ((MP)->mnt_kern_flag & (FLAG)))

#define VFS_MPLOCK1(MP) \
    if (VFS_NEEDMPLOCK(MP)) get_mplock()
    
#define VFS_MPLOCK2(MP) \
    if (VFS_NEEDMPLOCK(MP)) rel_mplock()
```

### Common VOP Wrappers

**File access operations:**
- `vop_open()` - Open file/device
- `vop_close()` - Close file/device
- `vop_access()` - Check access permissions
- `vop_read()` - Read from vnode
- `vop_write()` - Write to vnode
- `vop_ioctl()` - Device/file control
- `vop_fsync()` - Sync file data to disk

**Namespace operations (old API):**
- `vop_old_lookup()` - Look up name in directory
- `vop_old_create()` - Create regular file
- `vop_old_mkdir()` - Create directory
- `vop_old_rmdir()` - Remove directory
- `vop_old_unlink()` - Remove file

**Namespace operations (new API):**
- `vop_nresolve()` - Resolve name to vnode (nchandle-based)
- `vop_ncreate()` - Create file (nchandle-based)
- `vop_nmkdir()` - Create directory (nchandle-based)
- `vop_nremove()` - Remove file (nchandle-based)
- `vop_nrmdir()` - Remove directory (nchandle-based)
- `vop_nrename()` - Rename file (nchandle-based)

**Metadata operations:**
- `vop_getattr()` - Get file attributes
- `vop_setattr()` - Set file attributes
- `vop_getpages()` - Get VM pages for file
- `vop_putpages()` - Write VM pages back

**Directory operations:**
- `vop_readdir()` - Read directory entries
- `vop_readlink()` - Read symbolic link target

### Example: vop_open()

From `sys/kern/vfs_vopops.c:148`:

```c
int
vop_open(struct vop_ops *ops, struct vnode *vp, int mode,
         struct ucred *cred, struct file *file)
{
    struct vop_open_args ap;
    int error;

    ap.a_head.a_ops = ops;
    ap.a_head.a_desc = &vop_open_desc;
    ap.a_vp = vp;
    ap.a_mode = mode;
    ap.a_cred = cred;
    ap.a_fp = file;

    VFS_MPLOCK1(vp->v_mount);
    error = vop_open_ap(&ap);
    VFS_MPLOCK2(vp->v_mount);
    
    return error;
}
```

## High-Level Vnode Operations

The file `sys/kern/vfs_vnops.c` provides high-level operations built on top of VOP primitives. These functions are used by system calls and kernel subsystems.

### vn_open() - Complex File Opening

Located at `sys/kern/vfs_vnops.c:80`.

**Purpose:** Open a file given a namecache path, handling permissions, device special files, and various flags.

**Key responsibilities:**
1. Resolve path via namecache (`ncp->nc_vp`)
2. Check access permissions
3. Handle special cases (directories, block devices)
4. Call `VOP_OPEN()` on underlying filesystem
5. Set up sequential I/O heuristics if appropriate
6. Handle `O_TRUNC` flag for truncation after open

**Important checks:**
- Block opening directories for writing
- Enforce read-only mounts
- Handle device opens specially (pass to device driver)
- Manage vnode reference counts

**Sequential I/O heuristics:**
- If opened with `FREAD | FWRITE` and not `FAPPEND`, sets `VSEQIO` flag
- Helps buffer cache optimize for sequential access patterns

### vn_close() - File Closing

Located at `sys/kern/vfs_vnops.c:229`.

**Purpose:** Close an open file, synchronizing if needed and releasing resources.

**Operations:**
1. Call `VOP_CLOSE()` on filesystem
2. Clear sequential I/O flag if set
3. Release vnode reference via `vrele()`

### vn_rdwr() and vn_rdwr_inchunks() - Kernel I/O

Located at `sys/kern/vfs_vnops.c:262` and `sys/kern/vfs_vnops.c:321`.

**Purpose:** Perform read or write operations from kernel context.

**Key features:**
- Used for kernel-to-kernel I/O (e.g., loading executables, swap, core dumps)
- `vn_rdwr_inchunks()` splits large I/O into manageable chunks (limited by `iosize_max()`)
- Handles both UIO_USERSPACE and UIO_SYSSPACE addresses
- Can perform synchronous I/O (`IO_SYNC` flag)
- Manages file offset locking for concurrent access

**Common flags:**
- `IO_UNIT` - Atomic operation (all or nothing)
- `IO_APPEND` - Append to end of file
- `IO_SYNC` - Synchronous write (wait for disk)
- `IO_NODELOCKED` - Node already locked
- `IO_SEQMAX` - Maximum sequential I/O heuristic

### vn_read() - Read from Vnode

Located at `sys/kern/vfs_vnops.c:455`.

**Purpose:** Read data from a vnode via VOP_READ.

**Sequential I/O detection:**
```c
if ((fp->f_flag & FSEQIO) || (vp->v_flag & VSEQIO))
    ioflag |= IO_SEQMAX;
```

If sequential I/O is detected, sets `IO_SEQMAX` flag to hint buffer cache to maximize read-ahead.

### vn_write() - Write to Vnode

Located at `sys/kern/vfs_vnops.c:508`.

**Purpose:** Write data to a vnode via VOP_WRITE.

**Key operations:**
1. Check for read-only mount
2. Set `IO_SEQMAX` if sequential
3. Call `VOP_WRITE()`
4. Update access time if configured

**Mount-level write protection:**
```c
if (vp->v_mount && (vp->v_mount->mnt_flag & MNT_RDONLY)) {
    error = EROFS;
    goto done;
}
```

### File Offset Locking

Located at `sys/kern/vfs_vnops.c:571` and `sys/kern/vfs_vnops.c:599`.

**Functions:**
- `vn_get_fpf_offset(struct file *fp, off_t *offset)` - Atomically read file offset
- `vn_set_fpf_offset(struct file *fp, off_t offset)` - Atomically set file offset

**Purpose:** Safely manipulate file position in multi-threaded contexts.

**Implementation:**
- Uses `spin_lock()` on `fp->f_spin`
- Returns offset via pointer argument
- Essential for concurrent file access

### vn_stat() - Get File Statistics

Located at `sys/kern/vfs_vnops.c:625`.

**Purpose:** Fill in a `struct stat` from vnode attributes.

**Operations:**
1. Call `VOP_GETATTR()` to get vnode attributes
2. Translate `struct vattr` to `struct stat`
3. Handle special fields (st_dev, st_ino, st_blocks, st_blksize)
4. Compute optimal I/O size based on filesystem block size

**Device number handling:**
- For device special files, uses `vp->v_rdev` as `st_rdev`
- Regular files use mount device number

### vn_ioctl() - I/O Control

Located at `sys/kern/vfs_vnops.c:741`.

**Purpose:** Perform ioctl operations on vnodes and underlying devices.

**Special handling:**
- `FIOSEEKDATA` / `FIOSEEKHOLE` - Sparse file support (find next data/hole)
- `FIOASYNC` - Enable/disable async I/O notifications
- `FIOSETOWN` / `FIOGETOWN` - Manage signal recipient for async I/O
- Falls through to `VOP_IOCTL()` for filesystem-specific operations

### Other Helper Functions

**vn_islocked() / vn_lock()**
- Query and acquire vnode locks
- Wrappers around `vn_lock_shared()` and `vn_lock_exclusive()`

**vn_fullpath() / vn_fullpath_global()**
- Reconstruct full pathname from vnode
- Uses namecache to traverse parent directories

**vn_touser() / vn_touser_pgcache()**
- Copy file data to user buffer
- Used for sendfile() and similar operations

## Old vs New API

DragonFly BSD is transitioning from an older nameiop-based API to a newer nchandle-based API. The two APIs coexist for backward compatibility.

### Old API (componentname-based)

**Characteristics:**
- Uses `struct componentname` to represent path components
- Operations like `vop_old_lookup()`, `vop_old_create()`, `vop_old_mkdir()`
- Directory operations split into multiple steps
- More complex locking requirements

**Example operations:**
```c
vop_old_lookup(struct vnode *dvp, struct vnode **vpp,
               struct componentname *cnp)
vop_old_create(struct vnode *dvp, struct vnode **vpp,
               struct componentname *cnp, struct vattr *vap)
```

### New API (nchandle-based)

**Characteristics:**
- Uses `struct nchandle` from namecache
- Operations like `vop_nresolve()`, `vop_ncreate()`, `vop_nmkdir()`
- Better integration with namecache
- Cleaner locking semantics
- Supports namecache aliasing

**Example operations:**
```c
vop_nresolve(struct nchandle *nch, struct vnode *dvp,
             struct ucred *cred)
vop_ncreate(struct nchandle *nch, struct vnode *dvp,
            struct vnode **vpp, struct ucred *cred,
            struct vattr *vap)
```

### API Translation

Modern filesystems should implement the new API. The compatibility layer in `vfs_default.c` provides automatic translation for filesystems that only implement the old API.

**Translation functions:**
- `vop_compat_nresolve()` → `vop_old_lookup()`
- `vop_compat_ncreate()` → `vop_old_create()`
- `vop_compat_nmkdir()` → `vop_old_mkdir()`
- `vop_compat_nlink()` → `vop_old_link()`
- `vop_compat_nremove()` → `vop_old_unlink()`
- `vop_compat_nrmdir()` → `vop_old_rmdir()`
- `vop_compat_nrename()` → `vop_old_rename()`

These shims extract `componentname` from `nchandle` and call the old API, then update the namecache with results.

## Compatibility Layer

The file `sys/kern/vfs_default.c` provides default implementations and compatibility shims.

### Default Operation Vector

Located at `sys/kern/vfs_default.c:110`:

```c
struct vop_ops default_vnode_vops = {
    .vop_default         = vop_defaultop,
    .vop_old_lookup      = vop_eopnotsupp,
    .vop_old_create      = vop_eopnotsupp,
    .vop_open            = vop_stdopen,
    .vop_close           = vop_stdclose,
    .vop_access          = vop_eopnotsupp,
    .vop_nresolve        = vop_compat_nresolve,
    .vop_ncreate         = vop_compat_ncreate,
    // ... many more
};
```

**Purpose:** Provide fallback handlers for filesystems that don't implement all operations.

### Error Return Functions

**vop_eopnotsupp()** - Returns `EOPNOTSUPP`
- Used for unimplemented optional operations
- Indicates operation not supported by this filesystem

**vop_einval()** - Returns `EINVAL`
- Used for operations that should never be called
- Indicates programming error

**vop_enotty()** - Returns `ENOTTY`
- Used for ioctl operations on non-tty vnodes

### Standard Implementations

**vop_stdopen() / vop_stdclose()**
- Minimal open/close handlers
- Just return success (0)

**vop_stdgetpages() / vop_stdputpages()**
- Standard VM integration
- Delegates to `vnode_pager_generic_getpages()` / `vnode_pager_generic_putpages()`

**vop_stdpathconf()**
- Returns standard pathconf values
- Handles `_PC_LINK_MAX`, `_PC_NAME_MAX`, `_PC_PIPE_BUF`, etc.

**vop_stdioctl()**
- Handles standard ioctls
- `FIOSEEKDATA` / `FIOSEEKHOLE` via `vop_helper_seek_hole()`

**vop_stdmountctl()**
- Default mount control operations
- Returns `EOPNOTSUPP` for unsupported operations

### Compatibility Shims

#### vop_compat_nresolve()

Located at `sys/kern/vfs_default.c:557`.

**Purpose:** Translate new-style `vop_nresolve()` to old-style `vop_old_lookup()`.

**Algorithm:**
1. Extract component name from nchandle
2. Allocate and populate `struct componentname`
3. Call `VOP_OLD_LOOKUP()` on parent directory
4. Update namecache with result
5. Release resources

**Key code:**
```c
struct componentname cn;
cn.cn_nameiop = NAMEI_LOOKUP;
cn.cn_flags = 0;
cn.cn_cred = ap->a_cred;
cn.cn_nameptr = ap->a_nch->ncp->nc_name;
cn.cn_namelen = ap->a_nch->ncp->nc_nlen;

error = VOP_OLD_LOOKUP(ap->a_dvp, &vp, &cn);
if (error == 0)
    cache_setvp(ap->a_nch, vp);
```

#### vop_compat_ncreate()

Located at `sys/kern/vfs_default.c:623`.

**Purpose:** Translate `vop_ncreate()` to `vop_old_create()`.

**Algorithm:**
1. Similar to nresolve, but uses `NAMEI_CREATE` flag
2. Calls `VOP_OLD_CREATE()`
3. Updates namecache with newly created vnode
4. Returns vnode via `ap->a_vpp`

#### vop_compat_nremove()

Located at `sys/kern/vfs_default.c:779`.

**Purpose:** Translate `vop_nremove()` to `vop_old_unlink()`.

**Algorithm:**
1. Extract vnode from nchandle (if cached)
2. Call `VOP_OLD_UNLINK()` with parent and component name
3. Call `cache_unlink()` to remove from namecache
4. Release vnode

**Important:** Must handle case where nchandle has no cached vnode yet.

#### vop_compat_nrename()

Located at `sys/kern/vfs_default.c:917`.

**Purpose:** Translate `vop_nrename()` to `vop_old_rename()`.

**Complexity:** Most complex shim due to:
- Four directory/file combinations (source dir/file, target dir/file)
- Namecache updates for both source and target
- Handling cross-directory renames
- Updating parent directory links (..)

### VFS Standard Operations

These handle filesystem-level (not vnode-level) operations:

**vfs_stdroot()** - Get root vnode of filesystem
**vfs_stdstatfs()** - Get filesystem statistics
**vfs_stdsync()** - Sync all dirty data on filesystem
**vfs_stdvptofh()** - Convert vnode to file handle
**vfs_stdfhtovp()** - Convert file handle to vnode

These are used when a filesystem doesn't provide custom implementations.

## Fileops Integration

VOP operations integrate with file descriptor operations via `struct fileops`. The structure `vnode_fileops` (defined in `sys/kern/vfs_vnops.c:1354`) provides the glue between file descriptor operations and VOP operations.

### vnode_fileops Structure

```c
struct fileops vnode_fileops = {
    .fo_read = vn_read,
    .fo_write = vn_write,
    .fo_ioctl = vn_ioctl,
    .fo_kqfilter = vn_kqfilter,
    .fo_stat = vn_stat,
    .fo_close = vn_closefile,
    .fo_shutdown = vn_shutdown
};
```

**Purpose:** When a file descriptor refers to a vnode, these functions are called for file operations.

### Mapping fo_* to VOP_*

**fo_read → vn_read() → VOP_READ()**
- Reads from file descriptor go through vnode read path

**fo_write → vn_write() → VOP_WRITE()**
- Writes to file descriptor go through vnode write path

**fo_ioctl → vn_ioctl() → VOP_IOCTL()**
- Ioctl operations on files/devices

**fo_stat → vn_stat() → VOP_GETATTR()**
- fstat() system call implementation

**fo_close → vn_closefile() → VOP_CLOSE()**
- Close file descriptor

**fo_shutdown → vn_shutdown() → VOP_SHUTDOWN()**
- Shutdown file descriptor (for socket-like operations)

## Call Flow Examples

### Opening a File: open() System Call

1. **System call handler** calls `kern_open()` (`sys/kern/kern_descrip.c`)
2. **Namei lookup** resolves path to namecache entry
3. **kern_open()** calls `vn_open()` with nchandle
4. **vn_open()** extracts vnode from namecache (`nch->ncp->nc_vp`)
5. **vn_open()** performs access checks
6. **vn_open()** calls `VOP_OPEN(vp->v_ops, ...)`
7. **VOP wrapper** handles MPLOCK, calls journal layer
8. **Filesystem handler** (e.g., `hammer2_vop_open()`) performs open
9. **Return path** propagates back to system call
10. **File descriptor** set up with `vnode_fileops`

### Reading from a File: read() System Call

1. **System call handler** calls `sys_read()` (`sys/kern/sys_generic.c`)
2. **sys_read()** looks up file descriptor
3. **Calls** `fo_read()` on file → `vnode_fileops.fo_read` → `vn_read()`
4. **vn_read()** sets up UIO structure with user buffer
5. **vn_read()** detects sequential I/O, sets `IO_SEQMAX`
6. **vn_read()** calls `VOP_READ()`
7. **VOP wrapper** handles MPLOCK
8. **Filesystem handler** (e.g., `hammer2_vop_read()`) performs read
   - May call `cluster_read()` for buffer cache integration
9. **Data copied** from kernel buffers to user space
10. **Return** byte count to user

### Creating a File: open() with O_CREAT

1. **System call handler** calls `kern_open()` with `O_CREAT` flag
2. **Namei lookup** with CREATE intent
3. If file doesn't exist, **calls** `VOP_NCREATE()` via namecache
4. **VOP wrapper** `vop_ncreate()` calls filesystem handler
5. **Filesystem** (e.g., `hammer2_vop_ncreate()`) creates inode and directory entry
6. **Namecache updated** with new vnode
7. **VOP_OPEN()** called on newly created vnode
8. **File descriptor** set up and returned to user

### Directory Lookup: stat() System Call

1. **System call handler** calls `kern_stat()` (`sys/kern/vfs_syscalls.c`)
2. **Namei lookup** resolves path via namecache
   - May call `VOP_NRESOLVE()` if not cached
3. **Filesystem handler** resolves name to vnode
4. **vn_stat()** called with vnode
5. **VOP_GETATTR()** retrieves vnode attributes
6. **vn_stat()** converts `struct vattr` to `struct stat`
7. **Copy** stat structure to user space
8. **Release** vnode reference

## Filesystem Implementation Guide

### Implementing a New Filesystem

To implement a new filesystem, you need to:

1. **Define a `vop_ops` structure** with handlers for all supported operations
2. **Implement new API operations** (`vop_nresolve`, `vop_ncreate`, etc.)
3. **Mark filesystem as MPSAFE** if using fine-grained locking
4. **Integrate with buffer cache** via `cluster_read()` / `cluster_write()`
5. **Handle reference counting** properly (vnode lifecycle)

### Minimal Operation Set

A minimal filesystem must implement:

**Required:**
- `vop_nresolve()` - Name resolution
- `vop_nlookupdotdot()` - Parent directory lookup (..)
- `vop_open()` / `vop_close()` - File open/close
- `vop_read()` / `vop_write()` - Data I/O
- `vop_getattr()` / `vop_setattr()` - Attribute access
- `vop_reclaim()` - Vnode cleanup

**For writable filesystems:**
- `vop_ncreate()` / `vop_nmkdir()` - File/directory creation
- `vop_nremove()` / `vop_nrmdir()` - File/directory removal
- `vop_fsync()` - Synchronize data

**For VM integration:**
- `vop_getpages()` / `vop_putpages()` - Page I/O

### Example: Implementing vop_nresolve()

```c
static int
myfs_vop_nresolve(struct vop_nresolve_args *ap)
{
    struct nchandle *nch = ap->a_nch;
    struct vnode *dvp = ap->a_dvp;
    struct vnode *vp;
    int error;

    /* Look up name in parent directory */
    error = myfs_lookup_name(dvp, nch->ncp->nc_name,
                             nch->ncp->nc_nlen, &vp);
    if (error == 0) {
        /* Found - cache positive result */
        cache_setvp(nch, vp);
        vrele(vp);  /* cache holds reference */
    } else if (error == ENOENT) {
        /* Not found - cache negative result */
        cache_setvp(nch, NULL);
    }
    
    return error;
}
```

### MPLOCK Considerations

**For MPLOCK-based filesystems:**
- Set `MNTK_MPSAFE` to 0 during mount
- VOP wrappers will automatically acquire/release MPLOCK
- Simpler to implement, but less scalable

**For fine-grained locking:**
- Set appropriate `MNTK_*_MPSAFE` flags during mount
- Use per-vnode, per-inode, or per-mount locks
- More complex, but better SMP scalability
- Must carefully order lock acquisition to avoid deadlock

### Integration Checklist

- [ ] Define `struct vop_ops` with all handlers
- [ ] Implement name cache integration (nresolve, ncreate, etc.)
- [ ] Implement data I/O (read, write, strategy)
- [ ] Implement attribute operations (getattr, setattr)
- [ ] Implement VM integration (getpages, putpages)
- [ ] Handle vnode lifecycle (reclaim, inactive)
- [ ] Integrate with buffer cache (if applicable)
- [ ] Set appropriate MPLOCK flags
- [ ] Handle reference counting correctly
- [ ] Test with VFS test suite

## Key Data Structures

### struct vnode

Defined in `sys/sys/vnode.h`. Represents a file or directory in the VFS layer.

**Key fields:**
- `v_ops` - Pointer to operation vector
- `v_mount` - Mount point this vnode belongs to
- `v_type` - Type (VREG, VDIR, VCHR, VBLK, etc.)
- `v_flag` - Flags (VROOT, VSEQIO, VRECLAIMED, etc.)
- `v_data` - Filesystem-private data (inode pointer)
- `v_usecount` - Reference count

### struct nchandle

Defined in `sys/sys/namecache.h`. Represents a namecache entry.

**Key fields:**
- `ncp` - Pointer to namecache entry (`struct namecache`)
- `mount` - Associated mount point

### struct namecache

Defined in `sys/sys/namecache.h`. Represents a cached directory entry.

**Key fields:**
- `nc_vp` - Cached vnode (NULL for negative cache)
- `nc_name` - Component name
- `nc_nlen` - Name length
- `nc_parent` - Parent directory nchandle

### struct componentname

Defined in `sys/sys/vnode.h`. Used by old API for name lookups (legacy).

**Key fields:**
- `cn_nameiop` - Operation (LOOKUP, CREATE, DELETE, RENAME)
- `cn_flags` - Flags (FOLLOW, LOCKPARENT, etc.)
- `cn_cred` - Credentials
- `cn_nameptr` - Pointer to name string
- `cn_namelen` - Length of name

### struct vattr

Defined in `sys/sys/vattr.h`. Represents file attributes.

**Key fields:**
- `va_type` - File type
- `va_mode` - Permission bits
- `va_uid` / `va_gid` - Owner/group
- `va_size` - File size
- `va_blocksize` - Preferred I/O block size
- `va_atime` / `va_mtime` / `va_ctime` - Timestamps
- `va_flags` - File flags (immutable, etc.)

## Debugging and Diagnostics

### VOP Call Tracing

Enable VOP tracing with DDB:

```
db> set vfs_debug_vop=1
```

This will log all VOP calls to the console.

### Common Errors

**EOPNOTSUPP** - Operation not supported
- Filesystem doesn't implement this VOP
- Check if default handler is being called

**EROFS** - Read-only filesystem
- Attempted write to read-only mount
- Check mount flags

**ENOENT** - File not found
- Lookup failed
- Check namecache and on-disk directory

**EINVAL** - Invalid argument
- Wrong operation for vnode type
- Check vnode type (VREG, VDIR, etc.)

**Deadlock detection:**
- Use lock validation in DEBUG kernels
- Check lock ordering in filesystem code

### Useful Sysctls

```
vfs.timestamp_precision - Timestamp resolution (0=sec, 1=ms, 2=us, 3=ns)
vfs.read_max - Maximum read size
vfs.write_max - Maximum write size
vfs.hirunningspace - High water mark for async writes
```

## Summary

The VFS operations framework provides a sophisticated, layered architecture for implementing filesystem operations in DragonFly BSD. Key takeaways:

1. **VOP dispatch** provides uniform interface across filesystem types
2. **Wrapper layer** handles locking (MPLOCK) and journaling transparently
3. **Two API generations** coexist with automatic compatibility translation
4. **High-level operations** (`vn_*`) built on VOP primitives
5. **Default implementations** simplify filesystem development
6. **Fileops integration** connects file descriptors to VOP operations

The framework enables:
- Clean separation between VFS layer and filesystem implementations
- Gradual migration to modern APIs
- Flexible locking strategies (MPLOCK vs fine-grained)
- Transparent journaling support
- Extensibility for new filesystem types

**Related documentation:**
- [Name Cache](namecache.md) - Pathname lookup and caching
- [Buffer Cache](buffer-cache.md) - Block buffer management
- [Mounting](mounting.md) - Filesystem mounting and VFS infrastructure
- [VFS Overview](index.md) - VFS subsystem introduction
