# VFS Name Lookup and Caching

## Overview

The DragonFly BSD namecache subsystem provides a high-performance layer between pathname lookup operations and the underlying filesystem. It consists of three main components:

1. **Namecache (`vfs_cache.c`)** - The core caching infrastructure that maintains mappings between directory entries and vnodes
2. **New Lookup API (`vfs_nlookup.c`)** - Modern path resolution based on namecache records instead of vnode locking
3. **Legacy Lookup (`vfs_lookup.c`)** - Traditional BSD `namei()` compatibility for old code

The namecache is fundamental to DragonFly's VFS design and all filesystem operations must interact with it, even filesystems that don't want to cache.

## Key Data Structures

### `struct namecache` (`sys/namecache.h:125`)

The core namecache entry representing a single pathname component:

```c
struct namecache {
    TAILQ_ENTRY(namecache) nc_hash;      /* hash chain (nc_parent,name) */
    TAILQ_ENTRY(namecache) nc_entry;     /* scan via nc_parent->nc_list */
    TAILQ_ENTRY(namecache) nc_vnode;     /* scan via vnode->v_namecache */
    struct namecache_list  nc_list;      /* list of children */
    struct nchash_head    *nc_head;
    struct namecache      *nc_parent;    /* namecache entry for parent */
    struct vnode          *nc_vp;        /* vnode representing name or NULL */
    u_short               nc_flag;
    u_char                nc_nlen;       /* name length, 255 max */
    u_char                nc_unused;
    char                  *nc_name;      /* separately allocated segment name */
    int                   nc_error;
    int                   nc_timeout;    /* compared against ticks, or 0 */
    int                   nc_negcpu;     /* which ncneg list are we on? */
    struct {
        u_int             nc_namecache_gen; /* mount generation (autoclear) */
        u_int             nc_generation;    /* see notes below */
        int               nc_refs;          /* ref count prevents deletion */
    } __cachealign;
    struct {
        struct lock       nc_lock;
    } __cachealign;
};
```

**Key fields:**

- **`nc_parent`** - Points to parent directory's namecache entry, forming a tree from leaf to root
- **`nc_vp`** - The vnode this entry represents; NULL for negative cache entries (non-existent files)
- **`nc_name`** - The filename component (allocated separately)
- **`nc_list`** - Children of this directory entry
- **`nc_refs`** - Reference count (naturally 1, +1 if resolved, +1 for each child)
- **`nc_generation`** - Incremented by 2 when entry changes, allowing lock-free detection of modifications
- **`nc_flag`** - See flags below

**Important flags (`NCF_*`):**

- `NCF_UNRESOLVED` (0x0004) - Entry not yet resolved or invalidated
- `NCF_WHITEOUT` (0x0002) - Negative entry is a whiteout (for union mounts)
- `NCF_DESTROYED` (0x0400) - Name association considered destroyed
- `NCF_ISMOUNTPT` (0x0008) - Someone may have mounted here
- `NCF_ISSYMLINK` (0x0100) - Entry is a symlink
- `NCF_ISDIR` (0x0200) - Entry is a directory

### `struct nchandle` (`sys/namecache.h:154`)

A handle to a namecache entry with associated mount point:

```c
struct nchandle {
    struct namecache *ncp;    /* ncp in underlying filesystem */
    struct mount     *mount;  /* mount pt (possible overlay) */
};
```

The mount reference allows topologies to be replicated across mount overlays (nullfs, unionfs, etc.). This is DragonFly's key innovation for handling stacked filesystems.

### `struct nlookupdata` (`sys/nlookup.h:68`)

Encapsulates all state for a path lookup operation:

```c
struct nlookupdata {
    struct nchandle  nl_nch;       /* result */
    struct nchandle *nl_basench;   /* start-point directory */
    struct nchandle  nl_rootnch;   /* root directory */
    struct nchandle  nl_jailnch;   /* jail directory */
    
    char            *nl_path;      /* path buffer */
    struct thread   *nl_td;        /* thread requesting the nlookup */
    struct ucred    *nl_cred;      /* credentials for nlookup */
    struct vnode    *nl_dvp;       /* NLC_REFDVP */
    
    int              nl_flags;     /* operations flags */
    int              nl_loopcnt;   /* symlinks encountered */
    int              nl_dir_error; /* error assoc w/intermediate dir */
    int              nl_elmno;     /* iteration# to help caches */
    
    struct vnode    *nl_open_vp;
    int              nl_vp_fmode;
};
```

**Key flags (`NLC_*`):**

- `NLC_FOLLOW` (0x00000001) - Follow leaf symlink
- `NLC_CREATE` (0x00000080) - Do create checks
- `NLC_DELETE` (0x00000100) - Do delete checks
- `NLC_RENAME_SRC` (0x00002000) - Do rename checks (source)
- `NLC_RENAME_DST` (0x00000200) - Do rename checks (target)
- `NLC_OPEN` (0x00000400) - Do open checks
- `NLC_SHAREDLOCK` (0x00004000) - Allow shared ncp & vp lock
- `NLC_REFDVP` (0x00040000) - Set ref'd/unlocked nl_dvp
- `NLC_READ` (0x00400000) - Require read access
- `NLC_WRITE` (0x00800000) - Require write access
- `NLC_EXEC` (0x01000000) - Require execute access

### `struct nlcomponent` (`sys/nlookup.h:55`)

Represents a single path component during lookup:

```c
struct nlcomponent {
    char *nlc_nameptr;
    int   nlc_namelen;
};
```

## Architecture

### Namecache Topology

The DragonFly namecache maintains a **complete path from any active vnode to the root** (except for NFS server and removed files). This is a key difference from traditional BSD systems:

```
Root ("/")
  └─ bin/
      └─ ls (vnode)
  └─ usr/
      └─ local/
          └─ bin/
              └─ bash (vnode)
```

Each `namecache` entry points to its `nc_parent`, and parents maintain a list of children in `nc_list`. This bidirectional tree enables:

1. Efficient forward lookups (parent → child)
2. Efficient reverse path reconstruction (child → root for `getcwd()`)
3. Efficient subtree invalidation (e.g., when unmounting)

### Positive vs Negative Caching

**Positive entries:**
- `nc_vp` != NULL
- Represent files/directories that exist
- May be unresolved (NCF_UNRESOLVED) if not yet looked up

**Negative entries:**
- `nc_vp` == NULL
- Represent failed lookups (file doesn't exist)
- Stored in per-CPU negative lists for quick reclamation
- May be whiteouts (NCF_WHITEOUT) for union filesystems

Negative caching is crucial for performance, avoiding expensive filesystem lookups for common cases like:
- PATH searches in shell (`/bin/foo`, `/usr/bin/foo`, etc.)
- Probing for config files (`.bashrc`, `.config/app`, etc.)

### Hash Table Organization

The namecache uses a hash table indexed by `(nc_parent, name)`:

```c
#define NCHHASH(hash)  (&nchashtbl[(hash) & nchash])
```

Each hash bucket has its own spinlock. The implementation uses an update counter (`nc_generation`) to allow **lock-free lookups** in common cases - the code can detect if an entry changed during access and retry with locks if needed.

### Reference Counting

Namecache entries use `nc_refs` for lifecycle management:

- **Base ref**: 1 (entry exists)
- **Resolved ref**: +1 if entry is resolved (positive or negative)
- **Child refs**: +1 for each child in `nc_list`
- **Lookup refs**: +1 while held by threads or mountcache

On the **1→0 transition**, the entry must be destroyed immediately. The entry cannot be on any list at this point.

**Reference management functions:**

- `cache_hold()` / `cache_get()` - Acquire reference
- `cache_put()` - Release reference (drop lock + drop ref)
- `cache_drop()` - Release reference (no lock, just drop ref)
- `_cache_drop()` - Internal version that handles 1→0 transition

### Locking Strategy

DragonFly uses **child-to-parent lock ordering**:

1. Lock child first, then parent
2. Allows forward scans (parent → child) to hold parent unlocked
3. Deletions propagate bottom-up naturally

**Lock types:**

- **Exclusive locks** - Required for modifications, last element of path (unless NLC_SHAREDLOCK)
- **Shared locks** - Allowed for intermediate path components, read-only operations

The `nc_generation` field enables **optimistic lock-free access**:

```c
static __inline void
_cache_ncp_gen_enter(struct namecache *ncp)
{
    ncp->nc_generation += 2;  /* Odd = in-progress */
    cpu_sfence();
}

static __inline void
_cache_ncp_gen_exit(struct namecache *ncp)
{
    cpu_sfence();
    ncp->nc_generation += 2;  /* Even = stable */
    cpu_sfence();
}
```

If `(nc_generation & 1)` is set, modification is in progress. Readers check generation before and after access, retrying if it changed.

## Core Namecache Operations

### Path Lookup: `cache_nlookup()` (`vfs_cache.c:3228`)

Looks up a single path component in the cache:

```c
struct nchandle cache_nlookup(struct nchandle *par_nch, 
                              struct nlcomponent *nlc);
```

**Algorithm:**

1. **Hash lookup** - Compute `hash(parent, name)` and search bucket
2. **Lock-free scan** - Check each entry's generation before/after reading
3. **Match found** - Return referenced nchandle
4. **Miss** - Call `cache_nlookup_create()` to create unresolved entry
5. **Resolve** - Call `cache_resolve()` to resolve via VOP_NRESOLVE()

**Variants:**

- `cache_nlookup_nonblock()` - Returns immediately if lock unavailable
- `cache_nlookup_nonlocked()` - Optimistic lock-free lookup
- `cache_nlookup_maybe_shared()` - Allows shared locks if `!excl`

### Resolution: `cache_resolve()` (`vfs_cache.c:4273`)

Resolves an unresolved namecache entry by calling into the filesystem:

```c
int cache_resolve(struct nchandle *nch, u_int *genp, struct ucred *cred);
```

**Steps:**

1. Check if already resolved (fast path)
2. Check generation counter for races
3. Call `VOP_NRESOLVE(dvp, ncp, cred)` on parent directory
4. Filesystem fills in `ncp->nc_vp` or leaves NULL for negative entry
5. Clear `NCF_UNRESOLVED` flag

This is the **critical bridge** between namecache and filesystem-specific code.

### Invalidation: `cache_inval()` (`vfs_cache.c:1692`)

Invalidates a namecache entry:

```c
int cache_inval(struct nchandle *nch, int flags);
```

**Flags:**

- `CINV_DESTROY` (0x0001) - Mark destroyed so lookups ignore it
- `CINV_CHILDREN` (0x0004) - Recursively invalidate all children

**Use cases:**

- File/directory deletion
- Filesystem unmount
- Stale NFS entries

### Reference Management

**`cache_get()` (`vfs_cache.c:1293`)**

Acquires a reference and returns a handle:

```c
void cache_get(struct nchandle *nch, struct nchandle *target);
```

**`cache_put()` (`vfs_cache.c:1322`)**

Drops lock and reference:

```c
void cache_put(struct nchandle *nch);
```

**`cache_drop()` (`vfs_cache.c:1090`)**

Drops reference without affecting lock:

```c
void cache_drop(struct nchandle *nch);
```

**`cache_lock()` (`vfs_cache.c:1111`)**

Acquires exclusive lock on namecache entry:

```c
void cache_lock(struct nchandle *nch);
```

### Mount Point Caching

DragonFly caches mount point references to reduce atomic operations on `mnt_refs`:

**Per-CPU mount cache (`pcpu_mntcache`):**

```c
struct mntcache_elm {
    struct namecache *ncp;
    struct mount     *mp;
    int              ticks;
    int              unused01;
};
```

- 32 entries per CPU, 8-way set associative
- LRU replacement based on `ticks`
- Avoids cache-line ping-ponging in multi-socket systems

**Functions:**

- `_cache_mntref()` - Cache a mount ref
- `_cache_mntrel()` - Release a cached mount ref
- `cache_findmount()` - Find mount point for a namecache entry

## New Lookup API (nlookup)

The **nlookup** API is DragonFly's modern path resolution interface, replacing the traditional `namei()`.

### Key Advantages Over namei()

1. **Namecache-centric** - Operations work on namecache records, not vnodes
2. **Better parallelism** - Lock granularity is per-entry, not per-vnode
3. **Cleaner semantics** - Locked/unlocked state is explicit
4. **Overlay-aware** - Native support for nullfs, unionfs via `nchandle`
5. **Negative caching** - First-class support for non-existent entries

### Usage Pattern

```c
struct nlookupdata nd;
int error;

/* Initialize lookup */
error = nlookup_init(&nd, path, UIO_USERSPACE, NLC_FOLLOW);
if (error == 0) {
    /* Perform lookup */
    error = nlookup(&nd);
    if (error == 0) {
        /* Use nd.nl_nch result */
        struct nchandle *nch = &nd.nl_nch;
        struct vnode *vp;
        
        error = cache_vget(nch, cred, LK_EXCLUSIVE, &vp);
        if (error == 0) {
            /* ... use vp ... */
            vput(vp);
        }
    }
    /* Cleanup */
    nlookup_done(&nd);
}
```

### Core Functions

#### `nlookup_init()` (`vfs_nlookup.c:116`)

Initialize a lookup operation:

```c
int nlookup_init(struct nlookupdata *nd, const char *path, 
                 enum uio_seg seg, int flags);
```

**Setup:**

1. Allocate path buffer from `namei_oc` objcache
2. Copy path from userspace/kernelspace
3. Initialize `nl_nch` to current working directory (or root)
4. Copy root directory to `nl_rootnch`
5. Copy jail directory to `nl_jailnch` (if jailed)
6. Set credentials from current thread

#### `nlookup()` (`vfs_nlookup.c:530`)

Perform the actual path lookup:

```c
int nlookup(struct nlookupdata *nd);
```

**Main loop algorithm:**

```
for each path component:
    1. Skip leading '/' characters
    2. Check for root directory replacement
    3. Check execute permission on current directory (naccess)
    4. Extract next component (up to 255 chars)
    5. Handle special cases:
       - "." = current directory (no-op)
       - ".." = parent directory (traverse mounts)
       - regular name = cache_nlookup()
    6. If unresolved, call cache_resolve()
    7. Handle symlinks (if NLC_FOLLOW and nc_flag & NCF_ISSYMLINK)
    8. Handle mount point crossings
    9. Perform access checks based on nl_flags
    10. Update nl_nch to point to new entry
```

**Symlink handling:**

- Detect via `NCF_ISSYMLINK` flag
- Read symlink contents via `VOP_READLINK()`
- Restart lookup from symlink target
- Limit to `MAXSYMLINKS` (typically 32) to prevent loops

**Mount point traversal:**

```c
/* Cross into mounted filesystem */
if (nch.ncp->nc_flag & NCF_ISMOUNTPT) {
    mp = cache_findmount(&nch);
    if (mp) {
        /* Replace with mount point's root */
        cache_dropmount(mp);
    }
}
```

**Generation tracking:**

The code carefully tracks `nc_generation` throughout:

```c
nl_gen = nd->nl_nch.ncp->nc_generation & ~3;
...
if (gen_changed || (nl_gen & 1)) {
    /* Retry lookup */
    goto nlookup_start;
}
```

This allows detection of concurrent modifications and automatic retry.

#### `nlookup_done()` (`vfs_nlookup.c:289`)

Cleanup after lookup:

```c
void nlookup_done(struct nlookupdata *nd);
```

- Release all nchandles
- Free path buffer
- Drop credential reference
- Close `nl_open_vp` if set

### Access Checking: `naccess()` (`vfs_nlookup.c:1531`)

Check permissions during path traversal:

```c
static int naccess(struct nlookupdata *nd, struct nchandle *nch,
                   u_int *genp, int vmode, struct ucred *cred, 
                   int *stickyp, int nchislocked);
```

**Optimizations:**

1. **Cached permissions** - Check `NCF_WXOK` flag for world-searchable dirs
2. **Lock-free** - Avoids locking if cached perms are sufficient
3. **Generation tracking** - Detect races with `nc_generation`

## Legacy Lookup API (namei)

### `relookup()` (`vfs_lookup.c:75`)

Old API function used only by legacy `*_rename()` code:

```c
int relookup(struct vnode *dvp, struct vnode **vpp, 
             struct componentname *cnp);
```

This is a **compatibility shim**. New code should use nlookup exclusively.

**Key differences from nlookup:**

- Works with vnodes directly (requires vnode locks)
- Uses `componentname` instead of `nlcomponent`
- Less efficient due to vnode-based locking
- Does not support overlay mounts as cleanly

## Performance Optimizations

### Lock-Free Lookups

The core innovation is **optimistic lock-free access**:

```c
/* Fast path - no locks */
do {
    gen_before = ncp->nc_generation;
    cpu_lfence();
    /* ... read fields ... */
    cpu_lfence();
    gen_after = ncp->nc_generation;
} while (gen_before != gen_after || (gen_after & 1));
```

If generation matches and is even (not in-progress), the read is consistent.

### Per-CPU Negative Lists

Negative entries are stored in per-CPU lists (`pcpu_ncache[cpu].neg_list`):

```c
struct pcpu_ncache {
    struct spinlock       umount_spin;
    struct spinlock       neg_spin;
    struct namecache_list neg_list;
    long                  neg_count;
    long                  vfscache_negs;
    long                  vfscache_count;
    /* ... statistics ... */
} __cachealign;
```

**Benefits:**

- No inter-CPU contention on negative entry allocation/free
- Cache-line alignment prevents false sharing
- Quick reclamation when memory pressure hits

### Mount Reference Caching

The per-CPU mount cache (`pcpu_mntcache`) is critical for performance:

- **Problem**: Atomic ops on `mp->mnt_refs` cause cache-line bouncing
- **Solution**: Cache mount refs per-CPU, only updating global ref periodically
- **Result**: 10-100x reduction in cache misses on multi-socket systems

### Namecache Size Limits

DragonFly dynamically balances cache sizes:

```c
__read_mostly static int ncnegfactor = 16;   /* ratio of negative entries */
__read_mostly static int ncposfactor = 16;   /* ratio of unres+leaf entries */
```

Functions like `_cache_cleanneg()` and `_cache_cleanpos()` trim caches when:

1. Memory pressure increases
2. Ratios exceed configured factors
3. Mount/unmount operations occur

## Filesystem Integration

### Required VOP Operations

Filesystems must implement these to integrate with namecache:

#### `VOP_NRESOLVE()`

Resolve an unresolved namecache entry:

```c
int VOP_NRESOLVE(struct vnode *dvp, struct namecache *ncp, 
                 struct ucred *cred);
```

**Responsibilities:**

1. Search directory `dvp` for name `ncp->nc_name`
2. If found: Call `cache_setvp(nch, vp)` to set `ncp->nc_vp`
3. If not found: Leave `ncp->nc_vp` as NULL (negative entry)
4. Return 0 on success, error otherwise

#### `VOP_NCREATE()`

Create file via namecache:

```c
int VOP_NCREATE(struct vnode *dvp, struct vnode **vpp,
                struct nchandle *nch, struct vattr *vap,
                struct ucred *cred);
```

#### `VOP_NREMOVE()`

Remove file via namecache:

```c
int VOP_NREMOVE(struct vnode *dvp, struct nchandle *nch,
                struct ucred *cred);
```

#### `VOP_NRENAME()`

Rename via namecache:

```c
int VOP_NRENAME(struct nchandle *fnch, struct nchandle *tnch,
                struct vnode *fdvp, struct vnode *tdvp,
                struct ucred *cred);
```

### Invalidation Requirements

Filesystems must invalidate namecache entries when:

1. **File/directory deleted** - `cache_inval(nch, CINV_DESTROY)`
2. **Directory modified** - `cache_inval_vp(dvp, CINV_CHILDREN)`
3. **Vnode recycled** - `cache_inval_vp(vp, CINV_DESTROY)`
4. **Mount/unmount** - `cache_purgevfs(mp)`

**Example (tmpfs):**

```c
/* After unlinking a file */
error = tmpfs_remove_dirent(dvp, node, nch);
if (error == 0) {
    cache_inval(nch, CINV_DESTROY);
    cache_inval_vp(vp, CINV_DESTROY);
}
```

## Special Cases

### Mount Point Handling

When a lookup encounters a mount point:

1. Detect via `NCF_ISMOUNTPT` flag
2. Call `cache_findmount(nch)` to get mounted filesystem
3. Replace `nch` with mount point's root `mp->mnt_ncmountpt`
4. Continue lookup in new filesystem

**Reverse traversal (`..'):**

```c
while (nctmp.ncp == nctmp.mount->mnt_ncmountpt.ncp) {
    /* Traverse to mounted-on directory */
    nctmp = nctmp.mount->mnt_ncmounton;
}
nctmp.ncp = nctmp.ncp->nc_parent;
```

### Jail and Chroot

The lookup code respects process jails and chroot:

- `nl_rootnch` - Process's root (may be chrooted)
- `nl_jailnch` - Jail's root (if jailed)

**Root clamping:**

```c
if (nd->nl_nch.mount == nd->nl_rootnch.mount &&
    nd->nl_nch.ncp == nd->nl_rootnch.ncp) {
    /* At root, ".." returns root */
    cache_copy(&nd->nl_rootnch, &nch);
}
```

### Whiteouts (Union Mounts)

Whiteouts represent explicitly deleted entries in union filesystems:

- Negative entry with `NCF_WHITEOUT` flag set
- Prevents lower layers from showing through
- Created by `VOP_NWHITEOUT()`

## Common Operations

### Get vnode from nchandle

```c
struct vnode *vp;
error = cache_vget(nch, cred, LK_EXCLUSIVE, &vp);
if (error == 0) {
    /* ... use vp ... */
    vput(vp);  /* Release lock + ref */
}
```

### Get nchandle from vnode

```c
struct nchandle nch;
error = cache_fromdvp(vp, cred, 1, &nch);
if (error == 0) {
    /* ... use nch ... */
    cache_drop(&nch);
}
```

### Full path from nchandle

```c
char *freebuf;
char *fullpath;
error = cache_fullpath(p, nch, NULL, &fullpath, &freebuf, 0);
if (error == 0) {
    kprintf("Path: %s\n", fullpath);
    kfree(freebuf, M_TEMP);
}
```

### Check if path is open

```c
if (cache_isopen(nch)) {
    /* Entry has open file descriptors */
}
```

## Statistics and Debugging

### Sysctl Variables

```
vfs.cache.numneg       - Number of negative entries
vfs.cache.numcache     - Total namecache entries
vfs.cache.numleafs     - Leaf entries (no children)
vfs.cache.numunres     - Unresolved leaf entries
```

### Per-CPU Statistics (`struct nchstats`)

Exported via `vfs.cache.nchstats` sysctl:

- `ncs_goodhits` - Successful cache hits
- `ncs_neghits` - Negative cache hits
- `ncs_badhits` - Hits that required locking
- `ncs_miss` - Cache misses requiring VOP_NRESOLVE
- `ncs_longhits` - Long name hits (> 32 chars)

### Debug Variables

```
debug.ncvp_debug       - Namecache debug level (0-3)
debug.ncnegflush       - Batch flush negative entries
debug.ncposflush       - Batch flush positive entries
debug.nclockwarn       - Warn on locked entries in ticks
```

## Example: Creating a File

```c
struct nlookupdata nd;
struct vnode *vp;
struct vattr vat;
int error;

/* Lookup parent directory and target name */
error = nlookup_init(&nd, "/tmp/newfile", UIO_SYSSPACE, NLC_FOLLOW);
if (error == 0) {
    nd.nl_flags |= NLC_CREATE;
    error = nlookup(&nd);
    if (error == 0) {
        /* Setup attributes */
        VATTR_NULL(&vat);
        vat.va_type = VREG;
        vat.va_mode = 0644;
        
        /* Get parent directory vnode */
        error = cache_vget(&nd.nl_nch, cred, LK_EXCLUSIVE, &vp);
        if (error == 0) {
            /* Create the file */
            error = VOP_NCREATE(vp, &vp, &nd.nl_nch, &vat, cred);
            if (error == 0) {
                /* ... file created, vp is new file ... */
                vput(vp);
            } else {
                vput(vp);
            }
        }
    }
    nlookup_done(&nd);
}
```

## Summary

The DragonFly namecache and nlookup system provides:

1. **High-performance caching** with lock-free reads
2. **Negative caching** to avoid redundant lookups
3. **Clean API** separating pathname lookup from vnode operations
4. **Native overlay support** via nchandle abstraction
5. **Fine-grained locking** for better SMP scalability
6. **Complete path maintenance** from leaf to root

This design is a significant improvement over traditional BSD namecache, enabling better performance on modern multi-core systems while simplifying filesystem implementation.

## Related Documentation

- [VFS Core](index.md) - VFS subsystem overview
- [VFS Mounting](mounting.md) - Mount point management (Phase 6c)
- [Process File Descriptors](../processes.md) - `fd_ncdir`, `fd_nrdir` usage

## Source Files

- `sys/kern/vfs_cache.c` (~5,000 lines) - Namecache implementation
- `sys/kern/vfs_nlookup.c` (~2,300 lines) - New lookup API
- `sys/kern/vfs_lookup.c` (~160 lines) - Legacy lookup API
- `sys/sys/namecache.h` - Namecache structures and API
- `sys/sys/nlookup.h` - nlookup structures and flags
