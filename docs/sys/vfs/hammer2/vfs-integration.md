# HAMMER2 VFS Integration

This document describes how HAMMER2 integrates with the DragonFly BSD VFS layer,
covering mount/unmount operations, vnode operations, and the key data structures
that bridge the filesystem with the kernel.

**Source files:**

- `sys/vfs/hammer2/hammer2_vfsops.c` - VFS operations (mount, unmount, sync, statfs)
- `sys/vfs/hammer2/hammer2_vnops.c` - Vnode operations (read, write, lookup, etc.)
- `sys/vfs/hammer2/hammer2.h` - Structure definitions

## Key Data Structures

### hammer2_dev_t (hmp)

The `hammer2_dev_t` structure represents a physical block device mount. A single
device can host multiple PFSs (Pseudo-FileSystems), each potentially part of
different clusters.

```c
struct hammer2_dev {
    struct vnode    *devvp;         /* device vnode for root volume */
    int             ronly;          /* read-only mount */
    int             mount_count;    /* number of actively mounted PFSs */
    
    hammer2_chain_t vchain;         /* anchor chain (volume topology) */
    hammer2_chain_t fchain;         /* anchor chain (freemap) */
    struct hammer2_pfs *spmp;       /* super-root pmp for transactions */
    
    hammer2_volume_data_t voldata;  /* in-memory volume header */
    hammer2_volume_data_t volsync;  /* synchronized voldata */
    
    hammer2_io_hash_t iohash[HAMMER2_IOHASH_SIZE];  /* DIO cache */
    hammer2_devvp_list_t devvpl;    /* list of device vnodes */
    hammer2_volume_t volumes[HAMMER2_MAX_VOLUMES];  /* volume array */
    
    int             volhdrno;       /* last volume header written */
    hammer2_off_t   total_size;     /* total size of all volumes */
    int             nvolumes;       /* number of volumes */
    /* ... additional fields ... */
};
```

**Key relationships:**

- `vchain` - Root of the volume's block topology (type `HAMMER2_BREF_TYPE_VOLUME`)
- `fchain` - Root of the freemap topology (type `HAMMER2_BREF_TYPE_FREEMAP`)
- `spmp` - Super-root PFS used for device-level transactions
- `voldata` - Copy of the on-disk volume header

**Defined at:** `hammer2.h:1126`

### hammer2_pfs_t (pmp)

The `hammer2_pfs_t` structure represents a mounted PFS (Pseudo-FileSystem). Each
PFS can be independently mounted and may be part of a multi-node cluster.

```c
struct hammer2_pfs {
    struct mount        *mp;            /* system mount point */
    uuid_t              pfs_clid;       /* PFS cluster ID */
    hammer2_dev_t       *spmp_hmp;      /* non-NULL if super-root pmp */
    hammer2_inode_t     *iroot;         /* PFS root inode */
    
    uint8_t             pfs_types[HAMMER2_MAXCLUSTER];
    char                *pfs_names[HAMMER2_MAXCLUSTER];
    hammer2_dev_t       *pfs_hmps[HAMMER2_MAXCLUSTER];
    
    hammer2_trans_t     trans;          /* transaction state */
    int                 ronly;          /* read-only mount */
    
    hammer2_tid_t       modify_tid;     /* modify transaction id */
    hammer2_tid_t       inode_tid;      /* next inode number */
    uint8_t             pfs_nmasters;   /* total masters in cluster */
    
    hammer2_inum_hash_t inumhash[HAMMER2_INUMHASH_SIZE];  /* inode cache */
    struct inoq_head    syncq;          /* inodes pending sync */
    struct depq_head    depq;           /* side-queue inodes */
    
    hammer2_xop_group_t *xop_groups;    /* XOP worker threads */
    /* ... additional fields ... */
};
```

**Key relationships:**

- `mp` - Pointer to the kernel `struct mount` (NULL if not mounted)
- `iroot` - Root inode of this PFS
- `pfs_hmps[]` - Array of device mounts backing this cluster

**Defined at:** `hammer2.h:1202`

### Accessor Macros

```c
/* Get pmp from mount point */
#define MPTOPMP(mp)  ((hammer2_pfs_t *)mp->mnt_data)

/* Get inode from vnode */
#define VTOI(vp)     ((hammer2_inode_t *)(vp)->v_data)
```

## VFS Operations

### VFS Operations Table

The VFS operations table is defined at `hammer2_vfsops.c:221`:

```c
static struct vfsops hammer2_vfsops = {
    .vfs_init       = hammer2_vfs_init,
    .vfs_uninit     = hammer2_vfs_uninit,
    .vfs_sync       = hammer2_vfs_sync,
    .vfs_mount      = hammer2_vfs_mount,
    .vfs_unmount    = hammer2_vfs_unmount,
    .vfs_root       = hammer2_vfs_root,
    .vfs_statfs     = hammer2_vfs_statfs,
    .vfs_statvfs    = hammer2_vfs_statvfs,
    .vfs_vget       = hammer2_vfs_vget,
    .vfs_vptofh     = hammer2_vfs_vptofh,
    .vfs_fhtovp     = hammer2_vfs_fhtovp,
    .vfs_checkexp   = hammer2_vfs_checkexp,
    .vfs_modifying  = hammer2_vfs_modifying
};
```

### Module Initialization

**Function:** `hammer2_vfs_init()` at `hammer2_vfsops.c:245`

Called when the HAMMER2 module is loaded. Performs:

1. **XOP thread calculation** - Determines worker thread count based on CPU count:
   ```c
   hammer2_xop_nthreads = ncpus * 2;  /* minimum */
   ```

2. **Object cache creation** - Creates caches for:
   - `cache_buffer_read` - 64KB decompression buffers
   - `cache_buffer_write` - 32KB compression buffers
   - `cache_xops` - XOP operation structures

3. **Global list initialization**:
   - `hammer2_mntlist` - List of mounted devices
   - `hammer2_pfslist` - List of mounted PFSs
   - `hammer2_spmplist` - List of super-root PMPs

4. **Limit calculation**:
   ```c
   hammer2_limit_dirty_chains = maxvnodes / 10;
   hammer2_limit_dirty_inodes = maxvnodes / 25;
   ```

### Mount Operation

**Function:** `hammer2_vfs_mount()` at `hammer2_vfsops.c:913`

The mount operation handles both initial mounts and remounts (MNT_UPDATE).

#### Mount Flow

```
mount(2)
    |
    v
hammer2_vfs_mount()
    |
    +-- If MNT_UPDATE: call hammer2_remount()
    |
    +-- Parse device@LABEL specification
    |       - If no label: auto-select BOOT/ROOT/DATA based on slice
    |
    +-- Check if device already mounted (reuse existing hmp)
    |
    +-- If new device mount:
    |       |
    |       +-- hammer2_init_devvp() - Initialize device vnodes
    |       +-- hammer2_open_devvp() - Open device(s)
    |       +-- hammer2_init_volumes() - Read volume headers
    |       +-- Allocate hammer2_dev_t (hmp)
    |       +-- Initialize vchain and fchain
    |       +-- Lookup super-root inode
    |       +-- Create super-root PFS (spmp)
    |       +-- hammer2_recovery() - Perform recovery if needed
    |       +-- hammer2_update_pmps() - Scan and create PFS structures
    |
    +-- Lookup requested PFS label under super-root
    |
    +-- hammer2_pfsalloc() - Get/create PFS structure
    |
    +-- hammer2_mount_helper() - Connect mp to pmp
    |
    +-- vfs_add_vnodeops() - Register vnode operations:
            - hammer2_vnode_vops (regular files/directories)
            - hammer2_spec_vops (special devices)
            - hammer2_fifo_vops (FIFOs)
```

#### Label Auto-Selection

When no label is specified, HAMMER2 selects based on the partition:
- Slice 'a' -> `BOOT`
- Slice 'd' -> `ROOT`
- Other -> `DATA`

#### Super-Root Initialization

The super-root (`spmp`) is a special PFS that represents the device's namespace.
All user PFSs are stored as directory entries under the super-root.

```c
hmp->spmp = hammer2_pfsalloc(NULL, NULL, NULL);
spmp = hmp->spmp;
spmp->pfs_hmps[0] = hmp;
```

### Unmount Operation

**Function:** `hammer2_vfs_unmount()` at `hammer2_vfsops.c:1629`

```c
static int
hammer2_vfs_unmount(struct mount *mp, int mntflags)
{
    pmp = MPTOPMP(mp);
    
    /* Flush vnodes */
    error = vflush(mp, 0, flags);
    
    /* Three syncs required for complete flush:
     * 1. Flush data
     * 2. Flush freemap updates (lag by one)
     * 3. Safety sync
     */
    hammer2_vfs_sync(mp, MNT_WAIT);
    hammer2_vfs_sync(mp, MNT_WAIT);
    hammer2_vfs_sync(mp, MNT_WAIT);
    
    /* Cleanup XOP threads */
    hammer2_xop_helper_cleanup(pmp);
    
    /* Disconnect mount */
    hammer2_unmount_helper(mp, pmp, NULL);
}
```

The unmount helper (`hammer2_unmount_helper()`) handles:

1. Disconnecting `mp` from `pmp`
2. Decrementing `mount_count` on each backing device
3. If `mount_count` reaches zero, cleaning up the device:
   - Flushing vchain and fchain
   - Closing device vnodes
   - Freeing the `hammer2_dev_t`

### Root Vnode

**Function:** `hammer2_vfs_root()` at `hammer2_vfsops.c:1949`

Returns the root vnode for a mounted PFS:

```c
static int
hammer2_vfs_root(struct mount *mp, struct vnode **vpp)
{
    pmp = MPTOPMP(mp);
    
    hammer2_inode_lock(pmp->iroot, HAMMER2_RESOLVE_SHARED);
    
    /* First access may need to initialize inode_tid */
    while (pmp->inode_tid == 0) {
        /* Execute ipcluster XOP to get root inode data */
        xop = hammer2_xop_alloc(pmp->iroot, HAMMER2_XOP_MODIFYING);
        hammer2_xop_start(&xop->head, &hammer2_ipcluster_desc);
        /* ... initialize pmp->inode_tid and pmp->modify_tid ... */
    }
    
    *vpp = hammer2_igetv(pmp->iroot, &error);
    hammer2_inode_unlock(pmp->iroot);
    
    return error;
}
```

### Vnode Lookup by Inode Number

**Function:** `hammer2_vfs_vget()` at `hammer2_vfsops.c:1898`

Used by NFS and other subsystems to obtain a vnode given an inode number:

```c
int
hammer2_vfs_vget(struct mount *mp, struct vnode *dvp,
                 ino_t ino, struct vnode **vpp)
{
    inum = (hammer2_tid_t)ino & HAMMER2_DIRHASH_USERMSK;
    pmp = MPTOPMP(mp);
    
    /* Try inode cache first */
    ip = hammer2_inode_lookup(pmp, inum);
    if (ip) {
        *vpp = hammer2_igetv(ip, &error);
        return error;
    }
    
    /* Search via XOP */
    xop = hammer2_xop_alloc(pmp->iroot, 0);
    xop->lhc = inum;
    hammer2_xop_start(&xop->head, &hammer2_lookup_desc);
    error = hammer2_xop_collect(&xop->head, 0);
    
    if (error == 0)
        ip = hammer2_inode_get(pmp, &xop->head, -1, -1);
    
    if (ip)
        *vpp = hammer2_igetv(ip, &error);
}
```

## Vnode Operations

### Vnode Operations Table

The vnode operations table is defined at `hammer2_vnops.c:2481`:

```c
struct vop_ops hammer2_vnode_vops = {
    .vop_default        = vop_defaultop,
    .vop_fsync          = hammer2_vop_fsync,
    .vop_getpages       = vop_stdgetpages,
    .vop_putpages       = vop_stdputpages,
    .vop_access         = hammer2_vop_access,
    .vop_advlock        = hammer2_vop_advlock,
    .vop_close          = hammer2_vop_close,
    .vop_nlink          = hammer2_vop_nlink,
    .vop_ncreate        = hammer2_vop_ncreate,
    .vop_nsymlink       = hammer2_vop_nsymlink,
    .vop_nremove        = hammer2_vop_nremove,
    .vop_nrmdir         = hammer2_vop_nrmdir,
    .vop_nrename        = hammer2_vop_nrename,
    .vop_getattr        = hammer2_vop_getattr,
    .vop_getattr_lite   = hammer2_vop_getattr_lite,
    .vop_setattr        = hammer2_vop_setattr,
    .vop_readdir        = hammer2_vop_readdir,
    .vop_readlink       = hammer2_vop_readlink,
    .vop_read           = hammer2_vop_read,
    .vop_write          = hammer2_vop_write,
    .vop_open           = hammer2_vop_open,
    .vop_inactive       = hammer2_vop_inactive,
    .vop_reclaim        = hammer2_vop_reclaim,
    .vop_nresolve       = hammer2_vop_nresolve,
    .vop_nlookupdotdot  = hammer2_vop_nlookupdotdot,
    .vop_nmkdir         = hammer2_vop_nmkdir,
    .vop_nmknod         = hammer2_vop_nmknod,
    .vop_ioctl          = hammer2_vop_ioctl,
    .vop_mountctl       = hammer2_vop_mountctl,
    .vop_bmap           = hammer2_vop_bmap,
    .vop_strategy       = hammer2_vop_strategy,
    .vop_kqfilter       = hammer2_vop_kqfilter
};
```

Additional tables for special files (`hammer2_spec_vops`) and FIFOs
(`hammer2_fifo_vops`) are also defined.

### File Read

**Function:** `hammer2_vop_read()` at `hammer2_vnops.c:779`

```c
static int
hammer2_vop_read(struct vop_read_args *ap)
{
    ip = VTOI(vp);
    seqcount = ap->a_ioflag >> IO_SEQSHIFT;
    error = hammer2_read_file(ip, uio, seqcount);
    return error;
}
```

The internal `hammer2_read_file()` function:
1. Acquires shared locks on inode and truncate_lock
2. Loops over logical blocks using `cluster_readx()` for read-ahead
3. Copies data to userspace via `uiomovebp()`

### File Write

**Function:** `hammer2_vop_write()` at `hammer2_vnops.c:811`

```c
static int
hammer2_vop_write(struct vop_write_args *ap)
{
    ip = VTOI(vp);
    
    /* Check read-only and space */
    if (ip->pmp->ronly)
        return EROFS;
    if (hammer2_vfs_enospace(ip, uio->uio_resid, cred) > 1)
        return ENOSPC;
    
    /* Start transaction */
    hammer2_trans_init(ip->pmp, 0);
    
    error = hammer2_write_file(ip, uio, ioflag, seqcount);
    
    hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
    return error;
}
```

### Directory Reading

**Function:** `hammer2_vop_readdir()` at `hammer2_vnops.c:581`

Uses the XOP system to read directory entries:

```c
static int
hammer2_vop_readdir(struct vop_readdir_args *ap)
{
    ip = VTOI(ap->a_vp);
    
    hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
    
    /* Handle '.' and '..' entries */
    if (saveoff == 0) { /* '.' */ }
    if (saveoff == 1) { /* '..' */ }
    
    /* Scan directory via XOP */
    xop = hammer2_xop_alloc(ip, 0);
    xop->lkey = saveoff | HAMMER2_DIRHASH_VISIBLE;
    hammer2_xop_start(&xop->head, &hammer2_readdir_desc);
    
    for (;;) {
        error = hammer2_xop_collect(&xop->head, 0);
        if (error) break;
        
        /* Handle INODE or DIRENT block references */
        /* Write directory entry via vop_write_dirent() */
    }
    
    hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
    hammer2_inode_unlock(ip);
}
```

### Vnode Lifecycle

#### Inactive

**Function:** `hammer2_vop_inactive()` at `hammer2_vnops.c:73`

Called when the last reference to a vnode is released but it remains cached:

```c
static int
hammer2_vop_inactive(struct vop_inactive_args *ap)
{
    ip = VTOI(vp);
    
    hammer2_inode_lock(ip, 0);
    if (ip->flags & HAMMER2_INODE_ISUNLINKED) {
        /* Truncate file data */
        nvtruncbuf(vp, 0, nblksize, 0, 0);
        
        /* Mark for deletion */
        atomic_set_int(&ip->flags, HAMMER2_INODE_DELETING);
        hammer2_inode_delayed_sideq(ip);
        
        vrecycle(vp);
    }
    hammer2_inode_unlock(ip);
}
```

#### Reclaim

**Function:** `hammer2_vop_reclaim()` at `hammer2_vnops.c:133`

Called when the vnode is being recycled:

```c
static int
hammer2_vop_reclaim(struct vop_reclaim_args *ap)
{
    ip = VTOI(vp);
    
    vclrisdirty(vp);
    
    hammer2_inode_lock(ip, 0);
    vp->v_data = NULL;
    ip->vp = NULL;
    
    /* Ensure deletion is queued if needed */
    if ((ip->flags & HAMMER2_INODE_ISUNLINKED) &&
        !(ip->flags & HAMMER2_INODE_DELETING)) {
        atomic_set_int(&ip->flags, HAMMER2_INODE_DELETING);
        hammer2_inode_delayed_sideq(ip);
    }
    hammer2_inode_unlock(ip);
    
    hammer2_inode_drop(ip);  /* release vp reference */
}
```

### File Sync

**Function:** `hammer2_vop_fsync()` at `hammer2_vnops.c:199`

```c
static int
hammer2_vop_fsync(struct vop_fsync_args *ap)
{
    ip = VTOI(vp);
    
    hammer2_trans_init(ip->pmp, 0);
    
    /* Flush buffer cache */
    vfsync(vp, ap->a_waitfor, 1, NULL, NULL);
    bio_track_wait(&vp->v_track_write, 0, 0);
    
    /* Sync inode metadata */
    hammer2_inode_lock(ip, 0);
    if (ip->flags & (HAMMER2_INODE_RESIZED|HAMMER2_INODE_MODIFIED))
        hammer2_inode_chain_sync(ip);
    
    /* Flush chains */
    hammer2_inode_chain_flush(ip, HAMMER2_XOP_INODE_STOP);
    
    hammer2_inode_unlock(ip);
    hammer2_trans_done(ip->pmp, 0);
}
```

## Sysctl Tunables

HAMMER2 exposes numerous tunables under `vfs.hammer2`:

| Sysctl | Default | Description |
|--------|---------|-------------|
| `cluster_meta_read` | 1 | Metadata read-ahead (blocks) |
| `cluster_data_read` | 4 | Data read-ahead (blocks) |
| `cluster_write` | 0 | Write clustering |
| `dedup_enable` | 1 | Enable deduplication |
| `always_compress` | 0 | Always attempt compression |
| `flush_pipe` | 100 | Flush pipeline depth |
| `bulkfree_tps` | 5000 | Bulkfree transactions per second |
| `dio_limit` | varies | DIO cache size limit |
| `limit_dirty_chains` | varies | Max dirty chains |
| `limit_dirty_inodes` | varies | Max dirty inodes |

**Statistics (read-only):**

| Sysctl | Description |
|--------|-------------|
| `iod_file_read` | File data blocks read |
| `iod_meta_read` | Metadata blocks read |
| `iod_file_write` | File data blocks written |
| `iod_file_wdedup` | Deduplicated writes |
| `iod_inode_creates` | Inodes created |
| `iod_inode_deletes` | Inodes deleted |
| `chain_allocs` | Currently allocated chains |

## PFS and Cluster Concepts

### PFS Types

```c
#define HAMMER2_PFSTYPE_NONE        0x00
#define HAMMER2_PFSTYPE_CACHE       0x01
#define HAMMER2_PFSTYPE_SLAVE       0x03
#define HAMMER2_PFSTYPE_SOFT_SLAVE  0x04
#define HAMMER2_PFSTYPE_SOFT_MASTER 0x05
#define HAMMER2_PFSTYPE_MASTER      0x06
#define HAMMER2_PFSTYPE_SUPROOT     0x08
```

### Cluster Configuration

A cluster can span multiple devices and include multiple PFS nodes:

- `HAMMER2_MAXCLUSTER` (8) - Maximum nodes per cluster
- Each node can be MASTER, SLAVE, or other types
- `pfs_nmasters` tracks the number of master nodes
- Synchronization threads maintain consistency across nodes

### Super-Root

The super-root is a special PFS that:
- Is automatically created for each device mount
- Contains all user PFSs as directory entries
- Uses `inode_tid = 1` for PFS creation
- Is not directly mountable by users

## Error Handling

HAMMER2 uses internal error codes that are converted to standard errno values:

```c
#define HAMMER2_ERROR_EIO       0x00000001  /* -> EIO */
#define HAMMER2_ERROR_CHECK     0x00000002  /* -> EDOM */
#define HAMMER2_ERROR_ENOSPC    0x00000020  /* -> ENOSPC */
#define HAMMER2_ERROR_ENOENT    0x00000040  /* -> ENOENT */
/* ... etc ... */
```

Conversion is done via `hammer2_error_to_errno()` defined at `hammer2.h:1317`.

## See Also

- [HAMMER2 Overview](index.md)
- [Chain Layer](chain-layer.md) - Chain structures and operations
- [On-Disk Format](on-disk-format.md) - Media structures
- [Inode Layer](inode-layer.md) - Inode management
- [XOP System](xop-system.md) - Extended operations
- [VFS Operations](../../kern/vfs/vfs-operations.md) - Generic VFS framework
