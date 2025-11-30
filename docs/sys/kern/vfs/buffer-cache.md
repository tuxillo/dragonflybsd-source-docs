# VFS Buffer Cache and I/O

## Overview

The VFS buffer cache is a critical subsystem that mediates between the filesystem layer and the underlying storage devices while integrating tightly with the VM system. It provides caching for filesystem metadata and file data, manages asynchronous and synchronous I/O, implements read-ahead and write-behind optimizations, and coordinates between buffer-based and VM-page-based I/O.

**Key source files:**
- `sys/kern/vfs_bio.c` (4,659 lines) - Buffer cache management
- `sys/kern/vfs_cluster.c` (1,814 lines) - Cluster I/O optimization
- `sys/kern/vfs_vm.c` (503 lines) - VM integration
- `sys/sys/buf.h` - Buffer structure definitions
- `sys/sys/bio.h` - BIO layer structures

**Core responsibilities:**
- Cache filesystem blocks in memory
- Manage dirty data and write-behind
- Implement read-ahead for sequential access
- Cluster I/O operations for performance
- Integrate with VM system for unified caching
- Provide async/sync I/O primitives

## Buffer Structure

### struct buf

The `struct buf` (sys/sys/buf.h:153) is the central data structure representing a cached filesystem block:

```c
struct buf {
    /* Tree linkages */
    RB_ENTRY(buf) b_rbnode;         /* RB node in vnode clean/dirty tree */
    RB_ENTRY(buf) b_rbhash;         /* RB node in vnode hash tree */
    TAILQ_ENTRY(buf) b_freelist;    /* Free list position if not active */
    struct buf *b_cluster_next;     /* Next buffer (cluster code) */
    
    /* Vnode association */
    struct vnode *b_vp;             /* Vnode for this buffer */
    
    /* BIO translation layers */
    struct bio b_bio_array[NBUF_BIO]; /* Typically 6 layers */
    
    /* State and control */
    u_int32_t b_flags;              /* B_* flags */
    unsigned int b_qindex;          /* Buffer queue index */
    unsigned int b_qcpu;            /* Buffer queue CPU */
    unsigned char b_act_count;      /* Activity count (like vm_page) */
    unsigned char b_swindex;        /* Swap index */
    cpumask_t b_cpumask;            /* KVABIO API CPU mask */
    struct lock b_lock;             /* Buffer lock */
    buf_cmd_t b_cmd;                /* I/O command */
    
    /* Size fields */
    int b_bufsize;                  /* Allocated buffer size (filesystem block) */
    int b_runningbufspace;          /* When I/O is running, pipelining */
    int b_bcount;                   /* Valid bytes in buffer */
    int b_resid;                    /* Remaining I/O */
    int b_error;                    /* Error return */
    
    /* Data pointers */
    caddr_t b_data;                 /* Data pointer (KVA) */
    caddr_t b_kvabase;              /* Base KVA for buffer */
    int b_kvasize;                  /* Size of KVA for buffer */
    
    /* Dirty tracking */
    int b_dirtyoff;                 /* Offset in buffer of dirty region */
    int b_dirtyend;                 /* Offset of end of dirty region */
    
    /* Reference counting */
    int b_refs;                     /* FINDBLK_REF/bqhold()/bqdrop() */
    
    /* Page list management */
    struct xio b_xio;               /* Data buffer page list management */
    
    /* Filesystem dependencies */
    struct bio_ops *b_ops;          /* Bio_ops used w/ b_dep */
    union {
        struct workhead b_dep;      /* List of filesystem dependencies */
        void *b_priv;               /* Filesystem private data */
    };
};
```

**Key field groups:**

1. **Indexing**: b_rbnode, b_rbhash organize buffers by (vnode, offset)
2. **Bio layers**: b_bio_array[] provides I/O address translation
3. **State**: b_flags, b_cmd, b_error track buffer state
4. **Sizing**: b_bufsize (allocation), b_bcount (valid data), b_resid (remaining)
5. **Data**: b_data points to KVA, b_xio manages VM pages
6. **Dirty**: b_dirtyoff/b_dirtyend track partial dirty ranges

### BIO Layer Fields

**b_bio1** (b_bio_array[0]) - Logical layer:
- Contains logical offset (b_loffset = b_bio1.bio_offset)
- Used with primary vnode (bp->b_vp)
- Operations: `vn_strategy(bp->b_vp, &bp->b_bio1)`

**b_bio2** (b_bio_array[1]) - Physical layer:
- Contains device-relative offset (translated from logical)
- Used with device vnode in filesystems
- Set by VOP_BMAP() call

**Additional layers**: Allocated from object cache for device stacking (RAID, encryption, etc.)

### Buffer Flags (b_flags)

Buffer state flags (sys/sys/buf.h:304):

**Cache state:**
- `B_CACHE` (0x00000020) - Buffer found in cache, data valid
- `B_INVAL` (0x00002000) - Buffer does not contain valid info
- `B_DELWRI` (0x00000080) - Delayed write (dirty, needs flush)
- `B_DIRTY` (0x00200000) - Needs writing later

**I/O state:**
- `B_ERROR` (0x00000800) - I/O error occurred
- `B_EINTR` (0x00000400) - I/O was interrupted
- `B_IOISSUED` (0x00001000) - I/O has been issued (vfs can clear)

**VM integration:**
- `B_VMIO` (0x20000000) - Buffer tied to VM object
- `B_PAGING` (0x04000000) - Volatile paging I/O, bypass VMIO
- `B_RAM` (0x10000000) - Read-ahead mark

**Clustering:**
- `B_CLUSTER` (0x40000000) - Part of a cluster operation
- `B_CLUSTEROK` (0x00020000) - May be clustered with adjacent buffers

**Locking:**
- `B_LOCKED` (0x00004000) - Locked in core (not reusable)
- `B_KVABIO` (0x00010000) - Lockholder uses KVABIO API

**Lifecycle:**
- `B_AGE` (0x00000001) - Reuse more quickly
- `B_RELBUF` (0x00400000) - Release VMIO buffer
- `B_NOCACHE` (0x00008000) - Destroy buffer AND backing store

**Special:**
- `B_HEAVY` (0x00100000) - Heavy-weight buffer (needs special handling)
- `B_BNOCLIP` (0x00000100) - EOF clipping not allowed
- `B_NOTMETA` (0x00000004) - Not metadata (affects VM page handling)
- `B_MARKER` (0x00040000) - Special marker buffer in queue
- `B_HASHED` (0x00000040) - Indexed via v_rbhash_tree

**Tree linkage:**
- `B_VNCLEAN` (0x01000000) - On vnode clean list
- `B_VNDIRTY` (0x02000000) - On vnode dirty list

### Buffer Commands (buf_cmd_t)

I/O operation types (sys/sys/buf.h:87):

```c
typedef enum buf_cmd {
    BUF_CMD_DONE = 0,      /* I/O completed */
    BUF_CMD_READ,          /* Read operation */
    BUF_CMD_WRITE,         /* Write operation */
    BUF_CMD_FREEBLKS,      /* Free blocks */
    BUF_CMD_FORMAT,        /* Format operation */
    BUF_CMD_FLUSH,         /* Cache flush */
    BUF_CMD_SEEK,          /* Seek operation */
} buf_cmd_t;
```

## Buffer Queues

### Per-CPU Queue Structure

Buffers are organized into per-CPU queues to reduce lock contention (vfs_bio.c:72):

```c
enum bufq_type {
    BQUEUE_NONE,        /* not on any queue */
    BQUEUE_LOCKED,      /* locked buffers */
    BQUEUE_CLEAN,       /* non-B_DELWRI buffers */
    BQUEUE_DIRTY,       /* B_DELWRI buffers */
    BQUEUE_DIRTY_HW,    /* B_DELWRI buffers - heavy weight */
    BQUEUE_EMPTY,       /* empty buffer headers */
    
    BUFFER_QUEUES       /* number of buffer queues */
};

struct bufpcpu {
    struct spinlock spin;
    struct bqueues bufqueues[BUFFER_QUEUES];
} __cachealign;

struct bufpcpu bufpcpu[MAXCPU];
```

**Queue semantics:**

- **BQUEUE_NONE**: Buffer is actively in use (locked, doing I/O)
- **BQUEUE_LOCKED**: Buffer explicitly locked with B_LOCKED flag
- **BQUEUE_CLEAN**: Clean cached buffers eligible for reuse
- **BQUEUE_DIRTY**: Dirty buffers awaiting flush
- **BQUEUE_DIRTY_HW**: Heavy-weight dirty buffers (special flushing)
- **BQUEUE_EMPTY**: Empty buffer headers (no data allocated)

### Buffer Lifecycle Through Queues

1. **Allocation** (getnewbuf):
   - Pull from BQUEUE_EMPTY or BQUEUE_CLEAN
   - State: BQUEUE_NONE (in use)

2. **Active use**:
   - Buffer locked via BUF_LOCK()
   - State: BQUEUE_NONE
   - I/O operations performed

3. **Release** (brelse/bqrelse):
   - Unlock buffer
   - Move to appropriate queue:
     - B_DELWRI → BQUEUE_DIRTY or BQUEUE_DIRTY_HW
     - B_LOCKED → BQUEUE_LOCKED
     - Clean → BQUEUE_CLEAN

4. **Reuse** (getnewbuf):
   - Scan BQUEUE_CLEAN for victims
   - Invalidate and reallocate

5. **Flush** (buf_daemon):
   - Scan BQUEUE_DIRTY/BQUEUE_DIRTY_HW
   - Write dirty buffers asynchronously
   - Move to BQUEUE_CLEAN after write completes

## Buffer Cache Tuning Parameters

### Sysctl Tunables

Space management (vfs_bio.c:162-210):

```c
/* Operational control */
long maxbufspace;          /* Hard limit on buffer space */
long hibufspace;           /* Soft limit (high watermark) */
long lobufspace;           /* Low watermark */
long bufspace;             /* Current buffer space used */

long lodirtybufspace;      /* Trigger buf_daemon activation */
long hidirtybufspace;      /* High watermark for dirty buffers */
long dirtybufspace;        /* Current dirty buffer space */
long dirtybufcount;        /* Number of dirty buffers */
long dirtybufspacehw;      /* Dirty space (heavy-weight) */
long dirtybufcounthw;      /* Dirty count (heavy-weight) */

long lorunningspace;       /* Minimum space for active I/O */
long hirunningspace;       /* Maximum space for active I/O */
long runningbufspace;      /* Currently running I/O space */
long runningbufcount;      /* Currently running I/O count */

u_int flushperqueue;       /* Buffers to flush per queue (default: 1024) */
long bufcache_bw;          /* Buffer→VM transfer bandwidth (200 MB/s) */
```

**Watermark behavior:**

- **lobufspace → hibufspace**: Normal operation, allocate freely
- **> hibufspace**: Trigger aggressive buffer reclamation
- **lodirtybufspace → hidirtybufspace**: Normal dirty buffer accumulation
- **> hidirtybufspace**: Wake buf_daemon to flush aggressively
- **lorunningspace → hirunningspace**: Control I/O pipeline depth

### Buffer Daemon Threads

Two kernel threads manage buffer flushing (vfs_bio.c:155-156):

**bufdaemon_td** - Standard buffer daemon:
- Flushes BQUEUE_DIRTY when dirtybufspace > lodirtybufspace
- Triggered via bd_request atomic flag
- Writes dirty buffers asynchronously
- Moves flushed buffers to BQUEUE_CLEAN

**bufdaemonhw_td** - Heavy-weight buffer daemon:
- Flushes BQUEUE_DIRTY_HW
- Separate thread prevents deadlock (heavy buffers may need more buffers to flush)
- Triggered via bd_request_hw atomic flag

**bd_signal()** (vfs_bio.c:4522):
Wakes buffer daemons based on dirty space:

```c
static void bd_signal(long totalspace)
{
    if (totalspace > 0 &&
        runningbufspace + dirtykvaspace >= lodirtybufspace) {
        atomic_set_int(&bd_request, 1);
        wakeup(&bd_request);
        
        if (dirtybufspacehw > lodirtybufspace / 2) {
            atomic_set_int(&bd_request_hw, 1);
            wakeup(&bd_request_hw);
        }
    }
}
```

## Buffer Allocation

### getnewbuf() - Core Allocation

**getnewbuf()** (vfs_bio.c:1885)

Allocates a buffer for use, reusing existing buffers when necessary:

```c
struct buf *getnewbuf(int blkflags, int slptimeo, int size, int maxsize)
```

**Allocation strategy:**

1. **Check space limits**:
   ```c
   while (bufspace + maxsize > hibufspace)
       bufspacewakeup();  /* wait for space */
   ```

2. **Try BQUEUE_EMPTY** (fast path):
   - Pull empty buffer header
   - No data backing store yet

3. **Scan BQUEUE_CLEAN** (reuse path):
   - Look for buffers with B_AGE (prefer aged buffers)
   - Check lock availability (LK_NOWAIT)
   - Validate buffer can be reused:
     - Not locked (B_LOCKED clear)
     - Not in I/O (B_IOISSUED clear)
     - Not referenced (b_refs == 0)

4. **Flush and wait** (pressure path):
   - If no buffers available, flush BQUEUE_DIRTY
   - Wait for buffers to become available
   - Retry allocation

5. **Initialize buffer**:
   ```c
   bp->b_flags = B_CACHE;  /* Start cached */
   bp->b_cmd = BUF_CMD_DONE;
   bp->b_qindex = BQUEUE_NONE;
   bp->b_error = 0;
   ```

**Heavy-weight handling:**

Heavy-weight buffers (B_HEAVY) have restrictions:
- May need additional buffers to complete write
- Prevented from being allocated when dirty space is high
- Separate daemon thread (bufdaemonhw_td) for flushing

### getblk() - Cached Block Access

**getblk()** (vfs_bio.c:2729)

Main entry point for accessing cached filesystem blocks:

```c
struct buf *getblk(struct vnode *vp, off_t loffset, int size, 
                   int blkflags, int slptimeo)
```

**Lookup and allocation workflow:**

1. **Search vnode's buffer tree**:
   ```c
   bp = findblk(vp, loffset, FINDBLK_NBLOCK);
   if (bp) {
       /* Found in cache */
       if (BUF_LOCK(bp, LK_EXCLUSIVE | LK_NOWAIT)) {
           /* Lock contention, retry or wait */
       }
       return bp;  /* Cache hit */
   }
   ```

2. **Allocate new buffer**:
   ```c
   bp = getnewbuf(blkflags, slptimeo, size, maxsize);
   ```

3. **Insert into vnode's tree**:
   ```c
   lwkt_gettoken(&vp->v_token);
   /* Re-check for race (someone else inserted) */
   bp2 = findblk(vp, loffset, 0);
   if (bp2) {
       /* Lost race, use bp2 */
       brelse(bp);
       bp = bp2;
   } else {
       /* Won race, insert bp */
       bp->b_vp = vp;
       bp->b_loffset = loffset;
       buf_rb_tree_RB_INSERT(&vp->v_rbclean_tree, bp);
       buf_rb_hash_RB_INSERT(&vp->v_rbhash_tree, bp);
       bp->b_flags |= B_HASHED | B_VNCLEAN;
   }
   lwkt_reltoken(&vp->v_token);
   ```

4. **Handle size changes**:
   - If buffer exists but size doesn't match:
     - GETBLK_SZMATCH: Return NULL
     - Otherwise: Reallocate buffer with new size

5. **Initialize for use**:
   ```c
   if ((bp->b_flags & B_CACHE) == 0) {
       /* Not valid, caller must issue I/O */
       bp->b_flags &= ~(B_ERROR | B_INVAL);
       /* Don't set BUF_CMD_READ here, caller does it */
   }
   ```

**Flags:**
- `GETBLK_PCATCH`: Allow signals (can return NULL)
- `GETBLK_BHEAVY`: Mark as heavy-weight buffer
- `GETBLK_SZMATCH`: Fail if size doesn't match
- `GETBLK_NOWAIT`: Non-blocking lock
- `GETBLK_KVABIO`: Request KVABIO buffer

**Return states:**
- Buffer locked and ready for use
- B_CACHE set if data valid
- B_CACHE clear if I/O needed

## Buffer I/O Operations

### bread() - Synchronous Read

**bread()** (vfs_bio.c:857)

Reads a single block synchronously:

```c
int bread(struct vnode *vp, off_t loffset, int size, struct buf **bpp)
```

**Workflow:**

```c
/* Get buffer (from cache or allocate) */
bp = getblk(vp, loffset, size, 0, 0);

/* If not in cache, issue I/O */
if ((bp->b_flags & B_CACHE) == 0) {
    bp->b_flags &= ~(B_ERROR | B_EINTR | B_INVAL);
    bp->b_cmd = BUF_CMD_READ;
    bp->b_bio1.bio_done = biodone_sync;
    bp->b_bio1.bio_flags |= BIO_SYNC;
    vfs_busy_pages(vp, bp);
    vn_strategy(vp, &bp->b_bio1);
    error = biowait(&bp->b_bio1, "biord");
}

*bpp = bp;  /* Return locked buffer */
return error;
```

### breadn() - Read with Read-ahead

**breadn()** (vfs_bio.c:892)

Reads a block with optional read-ahead:

```c
int breadn(struct vnode *vp, off_t loffset, int size, int bflags,
           off_t *raoffset, int *rabsize, int cnt, struct buf **bpp)
```

**Read-ahead strategy:**

1. **Issue primary read** (synchronous):
   ```c
   bp = getblk(vp, loffset, size, 0, 0);
   if ((bp->b_flags & B_CACHE) == 0) {
       /* Issue sync I/O */
       vn_strategy(vp, &bp->b_bio1);
       readwait = 1;
   }
   ```

2. **Issue read-ahead requests** (asynchronous):
   ```c
   for (i = 0; i < cnt; i++) {
       if (inmem(vp, raoffset[i]))
           continue;  /* Already cached */
       
       rabp = getblk(vp, raoffset[i], rabsize[i], 0, 0);
       if ((rabp->b_flags & B_CACHE) == 0) {
           rabp->b_cmd = BUF_CMD_READ;
           BUF_KERNPROC(rabp);  /* Async, owned by kernel */
           vn_strategy(vp, &rabp->b_bio1);
       } else {
           brelse(rabp);  /* Already cached */
       }
   }
   ```

3. **Wait for primary read**:
   ```c
   if (readwait)
       error = biowait(&bp->b_bio1, "biord");
   ```

**Read-ahead benefits:**
- Overlap disk I/O with CPU processing
- Exploit sequential access patterns
- Improve throughput for streaming reads

### bwrite() - Synchronous Write

**bwrite()** (vfs_bio.c:963)

Writes a buffer synchronously:

```c
int bwrite(struct buf *bp)
```

**Workflow:**

```c
if (bp->b_flags & B_INVAL) {
    brelse(bp);
    return 0;
}

/* Clear errors, mark cached */
bp->b_flags &= ~(B_ERROR | B_EINTR);
bp->b_flags |= B_CACHE;
bp->b_cmd = BUF_CMD_WRITE;
bp->b_bio1.bio_done = biodone_sync;
bp->b_bio1.bio_flags |= BIO_SYNC;

vfs_busy_pages(bp->b_vp, bp);
bsetrunningbufspace(bp, bp->b_bufsize);  /* Account running space */
vn_strategy(bp->b_vp, &bp->b_bio1);

error = biowait(&bp->b_bio1, "biows");
brelse(bp);
return error;
```

**Key points:**
- Waits for I/O completion
- Sets B_CACHE (data valid after write)
- Tracks running I/O space
- Always releases buffer after completion

### bawrite() - Asynchronous Write

**bawrite()** (vfs_bio.c:1014)

Writes a buffer asynchronously:

```c
void bawrite(struct buf *bp)
```

**Differences from bwrite():**
- Does NOT wait for completion (no biowait)
- Uses default biodone (not biodone_sync)
- Marks buffer as kernel-owned (BUF_KERNPROC)
- Returns immediately

```c
bp->b_flags &= ~(B_ERROR | B_EINTR);
bp->b_flags |= B_CACHE;
bp->b_cmd = BUF_CMD_WRITE;
bp->b_bio1.bio_done = NULL;  /* Use default */

vfs_busy_pages(bp->b_vp, bp);
bsetrunningbufspace(bp, bp->b_bufsize);
BUF_KERNPROC(bp);  /* Transfer to kernel */
vn_strategy(bp->b_vp, &bp->b_bio1);
/* Returns immediately, I/O in progress */
```

### bdwrite() - Delayed Write

**bdwrite()** (vfs_bio.c:1060)

Marks a buffer dirty for later writing:

```c
void bdwrite(struct buf *bp)
```

**Delayed write behavior:**

```c
bdirty(bp);  /* Mark B_DELWRI, move to dirty tree */
bp->b_flags |= B_CACHE;

/* Pre-map physical block to avoid deadlock during sync */
if (bp->b_bio2.bio_offset == NOOFFSET) {
    VOP_BMAP(bp->b_vp, bp->b_loffset, 
             &bp->b_bio2.bio_offset, NULL, NULL, 
             BUF_CMD_WRITE);
}

/* Mark pages clean (earmarked for buffer flush) */
vfs_clean_pages(bp);
bqrelse(bp);  /* Release to dirty queue */
```

**Why delay writes?**
- Batch multiple writes together
- Allow cancellation (if file deleted)
- Enable write clustering
- Avoid synchronous delays

**VOP_BMAP call importance:**
- Pre-translates logical→physical block mapping
- Avoids needing buffers during sync (prevents deadlock)
- Memory for indirect blocks may not be available during sync

### bdirty() - Mark Buffer Dirty

**bdirty()** (vfs_bio.c:1163)

Core function to mark a buffer dirty:

```c
void bdirty(struct buf *bp)
{
    KASSERT(bp->b_qindex == BQUEUE_NONE, ...);
    
    bp->b_flags &= ~(B_RELBUF | B_NOCACHE);
    
    if ((bp->b_flags & B_DELWRI) == 0) {
        lwkt_gettoken(&bp->b_vp->v_token);
        bp->b_flags |= B_DELWRI;
        reassignbuf(bp);  /* Move from clean→dirty tree */
        lwkt_reltoken(&bp->b_vp->v_token);
        
        /* Update global counters */
        atomic_add_long(&dirtybufcount, 1);
        atomic_add_long(&dirtykvaspace, bp->b_kvasize);
        atomic_add_long(&dirtybufspace, bp->b_bufsize);
        if (bp->b_flags & B_HEAVY) {
            atomic_add_long(&dirtybufcounthw, 1);
            atomic_add_long(&dirtybufspacehw, bp->b_bufsize);
        }
        
        bd_heatup();  /* Signal buffer daemon */
    }
}
```

**reassignbuf()**: Moves buffer between vnode trees:
- From: `vp->v_rbclean_tree`, `B_VNCLEAN`
- To: `vp->v_rbdirty_tree`, `B_VNDIRTY`

### buwrite() - Fake Write (tmpfs)

**buwrite()** (vfs_bio.c:1127)

Used by tmpfs to mark pages dirty without writing to disk:

```c
void buwrite(struct buf *bp)
{
    /* Only for VMIO buffers */
    if ((bp->b_flags & B_VMIO) == 0 || (bp->b_flags & B_DELWRI)) {
        bdwrite(bp);
        return;
    }
    
    /* Mark VM pages as needing commit */
    for (i = 0; i < bp->b_xio.xio_npages; i++) {
        m = bp->b_xio.xio_pages[i];
        vm_page_need_commit(m);
    }
    
    bqrelse(bp);  /* Release without marking buffer dirty */
}
```

**Use case:**
- tmpfs stores data in VM pages, not disk
- Pages need marking dirty for VM system
- Buffer itself doesn't need writing

## Buffer Release

### brelse() - Standard Release

**brelse()** (vfs_bio.c:1268)

Releases a buffer back to the cache:

```c
void brelse(struct buf *bp)
```

**Release workflow:**

1. **Clear transient flags**:
   ```c
   bp->b_flags &= ~(B_IOISSUED | B_EINTR | B_NOTMETA | B_KVABIO);
   ```

2. **Handle B_NOCACHE** (destroy request):
   ```c
   if (bp->b_flags & B_NOCACHE) {
       bp->b_flags |= B_INVAL;
   }
   ```

3. **Handle B_INVAL** (invalidate):
   ```c
   if (bp->b_flags & B_INVAL) {
       if (bp->b_flags & (B_DELWRI | B_VNDIRTY))
           bundirty(bp);  /* Remove from dirty tree */
       if (bp->b_flags & B_HASHED)
           buf_rb_hash_RB_REMOVE(&vp->v_rbhash_tree, bp);
       if (bp->b_flags & (B_VNCLEAN | B_VNDIRTY))
           buf_rb_tree_RB_REMOVE(..., bp);
       bp->b_vp = NULL;
       bp->b_flags &= ~(B_HASHED | B_VNCLEAN | B_VNDIRTY);
   }
   ```

4. **Determine destination queue**:
   ```c
   if (bp->b_flags & B_LOCKED)
       qindex = BQUEUE_LOCKED;
   else if (bp->b_flags & B_DELWRI)
       qindex = (bp->b_flags & B_HEAVY) ? 
                BQUEUE_DIRTY_HW : BQUEUE_DIRTY;
   else if (bp->b_vp)
       qindex = BQUEUE_CLEAN;
   else
       qindex = BQUEUE_EMPTY;
   ```

5. **Insert into queue**:
   ```c
   spin_lock(&bufqspin);
   TAILQ_INSERT_TAIL(&bufqueues[qindex], bp, b_freelist);
   spin_unlock(&bufqspin);
   bp->b_qindex = qindex;
   ```

6. **Unlock buffer**:
   ```c
   BUF_UNLOCK(bp);
   ```

7. **Wake waiters**:
   ```c
   bufcountwakeup();  /* Wake anyone waiting for buffers */
   bufspacewakeup();  /* Wake anyone waiting for space */
   ```

### bqrelse() - Quick Release

**bqrelse()** (vfs_bio.c:1564)

Optimized release for buffers expected to be reused:

```c
void bqrelse(struct buf *bp)
```

**Difference from brelse():**
- Doesn't set B_AGE flag
- Leaves buffer in favorable position for reuse
- Used for metadata that's likely to be accessed again soon

## VM Integration (VMIO)

### VMIO Buffers

Buffers can be backed by VM pages instead of pure KVA (B_VMIO flag):

**Benefits:**
- Unified buffer cache and page cache
- Pages shared between mmap() and read()/write()
- Better memory utilization
- Supports direct I/O to user pages

**b_xio structure** (sys/sys/xio.h):
Manages the list of VM pages backing the buffer:

```c
struct xio {
    int xio_npages;                    /* Number of pages */
    int xio_flags;                     /* Flags */
    vm_page_t xio_pages[XIO_INTERNAL_PAGES];  /* Page array */
    struct vm_page *xio_internal_pages;        /* Internal storage */
};
```

### vfs_vmio_alloc() - Allocate VM Pages

**vfs_vmio_alloc()** (vfs_bio.c:2247)

Allocates VM pages to back a buffer:

```c
static int vfs_vmio_alloc(struct buf *bp, off_t loffset, 
                          int size, int bsize)
```

**Allocation workflow:**

1. **Calculate page range**:
   ```c
   vm_object_t obj = vp->v_object;
   off_t pgoff = loffset & PAGE_MASK;
   size_t npages = btoc(round_page(size + pgoff));
   ```

2. **Allocate/lookup pages**:
   ```c
   for (i = 0; i < npages; i++) {
       vm_pindex_t pg = btop(loffset) + i;
       m = bio_page_alloc(bp, obj, pg, ...);
       bp->b_xio.xio_pages[i] = m;
   }
   ```

3. **Set buffer properties**:
   ```c
   bp->b_flags |= B_VMIO;
   bp->b_data = (caddr_t)(pgoff + (vm_offset_t)m);
   bp->b_xio.xio_npages = npages;
   ```

### vfs_bio_clrbuf() - Clear Buffer

**vfs_bio_clrbuf()** (vfs_bio.c:729)

Zeros a buffer and validates all pages:

```c
void vfs_bio_clrbuf(struct buf *bp)
{
    if (bp->b_flags & B_VMIO) {
        /* Zero VM pages */
        for (i = 0; i < bp->b_xio.xio_npages; i++) {
            m = bp->b_xio.xio_pages[i];
            if (m->valid != VM_PAGE_BITS_ALL) {
                pmap_zero_page(m->phys_addr);
                m->valid = VM_PAGE_BITS_ALL;
                m->dirty = 0;
            }
        }
        bp->b_resid = 0;
    } else {
        /* Zero KVA */
        clrbuf(bp);
    }
    bp->b_flags |= B_CACHE;
}
```

### vfs_busy_pages() / vfs_unbusy_pages()

**vfs_busy_pages()** (vfs_bio.c:4051)

Prepares VM pages for I/O:

```c
void vfs_busy_pages(struct vnode *vp, struct buf *bp)
{
    if (bp->b_flags & B_VMIO) {
        for (i = 0; i < bp->b_xio.xio_npages; i++) {
            m = bp->b_xio.xio_pages[i];
            
            if (bp->b_cmd == BUF_CMD_READ) {
                m->flags &= ~PG_ZERO;
                vm_page_io_start(m);
            } else {
                vm_page_protect(m, VM_PROT_READ);
                vm_page_io_start(m);
            }
        }
    }
}
```

**vfs_unbusy_pages()** (vfs_bio.c:4096)

Completes I/O on VM pages:

```c
void vfs_unbusy_pages(struct buf *bp)
{
    if (bp->b_flags & B_VMIO) {
        for (i = 0; i < bp->b_xio.xio_npages; i++) {
            m = bp->b_xio.xio_pages[i];
            vm_page_io_finish(m);
            
            if (bp->b_cmd == BUF_CMD_READ && !error) {
                /* Mark page valid after successful read */
                m->valid = VM_PAGE_BITS_ALL;
            }
        }
    }
}
```

### vfs_vmio_release() - Release VM Pages

**vfs_vmio_release()** (vfs_bio.c:1233)

Releases VM pages when buffer destroyed:

```c
static void vfs_vmio_release(struct buf *bp)
{
    for (i = 0; i < bp->b_xio.xio_npages; i++) {
        m = bp->b_xio.xio_pages[i];
        bp->b_xio.xio_pages[i] = NULL;
        
        vm_page_busy_wait(m, FALSE, "vmiorl");
        
        /* Free page if appropriate */
        if (bp->b_flags & (B_NOCACHE | B_DIRECT)) {
            vm_page_try_to_free(m);
        } else {
            vm_page_try_to_cache(m);
        }
        vm_page_wakeup(m);
    }
    bp->b_xio.xio_npages = 0;
    bp->b_flags &= ~B_VMIO;
}
```

## Cluster I/O

### Overview

Cluster I/O optimization groups contiguous filesystem blocks into single I/O operations for improved throughput. Implemented in `sys/kern/vfs_cluster.c`.

**Benefits:**
- Reduces per-I/O overhead
- Better utilizes disk bandwidth
- Exploits spatial locality
- Amortizes seek time over multiple blocks

### Cluster Cache

**cluster_cache_t** structure (vfs_cluster.c:70):

```c
typedef struct cluster_cache {
    off_t cc_loffset;          /* Logical offset (cluster start) */
    off_t cc_lastloffset;      /* Last offset in cluster */
    int cc_flags;              /* Flags */
    struct vnode *cc_vp;       /* Vnode */
    int cc_refs;               /* Reference count */
} cluster_cache_t;

#define CLUSTER_CACHE_SIZE 16
cluster_cache_t cluster_array[CLUSTER_CACHE_SIZE];
```

**Per-vnode cluster state:**
- Tracks sequential access patterns
- Maintains read-ahead context
- Cached in global array indexed by vnode

**cluster_getcache() / cluster_putcache()**: Manage cluster cache entries

### cluster_read() - Clustered Read

**cluster_read()** (vfs_cluster.c:224)

Main entry point for clustered read operations:

```c
int cluster_read(struct vnode *vp, off_t filesize, off_t loffset,
                 int blksize, int totalbytes, int seqcount, 
                 struct buf **bpp)
```

**Parameters:**
- `filesize`: Total file size
- `loffset`: Logical offset to read
- `blksize`: Filesystem block size
- `totalbytes`: Total read size
- `seqcount`: Sequential access count (for read-ahead)
- `bpp`: Returns buffer pointer

**Read clustering workflow:**

1. **Check for existing buffer**:
   ```c
   bp = getblk(vp, loffset, blksize, 0, 0);
   if (bp->b_flags & B_CACHE) {
       *bpp = bp;
       return 0;  /* Cache hit */
   }
   ```

2. **Determine cluster size**:
   ```c
   /* Use seqcount to scale read-ahead */
   maxra = seqcount * blksize;
   maxra = min(maxra, MAXPHYS);  /* Cap at MAXPHYS (128KB) */
   ```

3. **Build read-ahead list**:
   ```c
   for (i = 1; i < maxblocks; i++) {
       if (inmem(vp, loffset + i * blksize))
           break;  /* Stop at cached block */
       raoffset[rablks] = loffset + i * blksize;
       rabsize[rablks] = blksize;
       rablks++;
   }
   ```

4. **Issue clustered I/O**:
   ```c
   error = cluster_rbuild(vp, filesize, bp, 
                          loffset, raoffset, rabsize, rablks);
   ```

5. **Update cluster cache**:
   ```c
   cc = cluster_getcache(NULL, vp, loffset);
   cc->cc_lastloffset = loffset + rablks * blksize;
   cluster_putcache(cc);
   ```

### cluster_rbuild() - Build Read Cluster

**cluster_rbuild()** (vfs_cluster.c:893)

Constructs a clustered read I/O operation:

```c
static int cluster_rbuild(struct vnode *vp, off_t filesize, 
                          struct buf *bp, off_t loffset,
                          off_t *raoffset, int *rabsize, int rablks)
```

**Clustering strategy:**

1. **Allocate read-ahead buffers**:
   ```c
   for (i = 0; i < rablks; i++) {
       rabp = getblk(vp, raoffset[i], rabsize[i], 0, 0);
       if (rabp->b_flags & B_CACHE) {
           brelse(rabp);
           continue;  /* Skip cached */
       }
       rabp->b_flags |= B_RAM;  /* Mark read-ahead */
       rabp->b_cmd = BUF_CMD_READ;
       /* Link into cluster chain */
       cluster_append(&bp->b_bio1, rabp);
   }
   ```

2. **Issue parent I/O**:
   ```c
   bp->b_cmd = BUF_CMD_READ;
   bp->b_bio1.bio_done = cluster_callback;
   bp->b_flags |= B_CLUSTER;
   vfs_busy_pages(vp, bp);
   vn_strategy(vp, &bp->b_bio1);
   ```

3. **Cluster callback** (cluster_callback):
   - Completes parent bio
   - Iterates child bios (read-ahead buffers)
   - Calls biodone() on each child
   - Releases buffers

**Chain structure:**
- Parent buffer has bio chain (bio->bio_caller_info.cluster_head)
- Child buffers linked via cluster_next
- All complete when parent I/O finishes

### cluster_write() - Clustered Write

**cluster_write()** (vfs_cluster.c:1244)

Attempts to cluster a write operation with adjacent dirty buffers:

```c
void cluster_write(struct buf *bp, off_t filesize, int blksize, int seqcount)
```

**Write clustering workflow:**

1. **Check if clustering allowed**:
   ```c
   if ((bp->b_flags & B_CLUSTEROK) == 0)
       goto out;  /* Filesystem doesn't allow clustering */
   if (bp->b_flags & B_LOCKED)
       goto out;  /* Locked buffer */
   ```

2. **Scan for adjacent dirty buffers**:
   ```c
   /* Scan backwards */
   for (i = 1; i <= maxback; i++) {
       tbp = findblk(vp, loffset - i * blksize, FINDBLK_TEST);
       if (!tbp || !(tbp->b_flags & B_DELWRI))
           break;
       /* Collect buffer */
   }
   
   /* Scan forwards */
   for (i = 1; i <= maxahead; i++) {
       tbp = findblk(vp, loffset + i * blksize, FINDBLK_TEST);
       if (!tbp || !(tbp->b_flags & B_DELWRI))
           break;
       /* Collect buffer */
   }
   ```

3. **Build cluster**:
   ```c
   cluster_wbuild(vp, bpp, numblks, start_loffset, blksize);
   ```

4. **Issue clustered write**:
   ```c
   if (nblocks == 1) {
       /* Single block, issue normally */
       bawrite(bp);
   } else {
       /* Multi-block cluster */
       for each buffer in cluster:
           cluster_append(&parent->b_bio1, child);
       vn_strategy(vp, &parent->b_bio1);
   }
   ```

**Write clustering benefits:**
- Reduces write overhead
- Better disk utilization
- Elevator seeking optimization
- Improved metadata write performance

### cluster_awrite() - Asynchronous Cluster Write

**cluster_awrite()** (vfs_cluster.c:1418)

Called during buffer flushing to attempt clustering:

```c
void cluster_awrite(struct buf *bp)
{
    /* If already doing I/O, skip */
    if (bp->b_flags & B_IOISSUED)
        return;
    
    /* Try to build cluster */
    cluster_write(bp, filesize, blksize, seqcount);
}
```

Called by buf_daemon when flushing BQUEUE_DIRTY.

### Sequential Access Detection

**sequential_heuristic()** (vfs_vnops.c):

Filesystem code tracks sequential access via VOP_READ/VOP_WRITE:

```c
int seqcount = (bp->b_flags & B_SEQMASK) >> B_SEQSHIFT;
if (loffset == last_loffset + blksize)
    seqcount = min(seqcount + 1, B_SEQMAX);  /* 127 max */
else
    seqcount = 0;  /* Reset on non-sequential */
```

**seqcount usage:**
- 0: Random access, minimal read-ahead
- >0: Sequential, scale read-ahead proportionally
- Max (127): Aggressive read-ahead (127 * blksize)

## BIO Operations

### BIO Layer Overview

The BIO (Block I/O) layer provides a flexible mechanism for I/O request transformation and stacking.

**struct bio** (sys/sys/bio.h):

```c
struct bio {
    struct bio *bio_next;          /* Next bio in chain */
    struct bio *bio_prev;          /* Previous bio */
    off_t bio_offset;              /* Logical offset (or block number) */
    struct buf *bio_buf;           /* Associated buffer */
    bio_track_t *bio_track;        /* I/O tracking */
    void (*bio_done)(struct bio *); /* Completion callback */
    void *bio_caller_info1;        /* Caller private data */
    union {
        void *cluster_head;        /* Cluster I/O head */
        void *cluster_parent;      /* Cluster parent */
    } bio_caller_info;
    u_int bio_flags;               /* BIO flags */
    ...
};
```

**BIO flags:**
- `BIO_SYNC` - Synchronous I/O
- `BIO_WANT` - Want notification on completion
- `BIO_DONE` - I/O completed

### Bio Callbacks

**biodone()** (vfs_bio.c:4201)

Default I/O completion handler:

```c
void biodone(struct bio *bio)
{
    struct buf *bp = bio->bio_buf;
    
    /* Call bio-specific done function if present */
    if (bio->bio_done) {
        bio->bio_done(bio);
        return;
    }
    
    /* Default completion */
    bufdone(bp);  /* Complete buffer I/O */
}
```

**biodone_sync()** (vfs_bio.c:4226)

Synchronous I/O completion:

```c
void biodone_sync(struct bio *bio)
{
    bio->bio_flags |= BIO_DONE;
    wakeup(bio);  /* Wake biowait() */
}
```

**biowait()** (vfs_bio.c:4243)

Wait for synchronous I/O completion:

```c
int biowait(struct bio *bio, const char *wmesg)
{
    while ((bio->bio_flags & BIO_DONE) == 0)
        tsleep(bio, 0, wmesg, 0);
    
    if (bio->bio_flags & BIO_ERROR)
        return bio->bio_buf->b_error;
    return 0;
}
```

### Bio Stacking

Device drivers and filesystems can push additional BIO layers:

```c
/* Filesystem layer (logical offset) */
vn_strategy(vp, &bp->b_bio1);
    ↓
/* Filesystem translates bio1 → bio2 */
VOP_STRATEGY(devvp, &bp->b_bio2);
    ↓
/* Device driver handles bio2 (physical offset) */
dev_dstrategy(...);
```

**Example: HAMMER filesystem**
1. bio1: File logical offset
2. bio2: HAMMER volume offset
3. bio3: Device physical offset

## Buffer Flushing

### buf_daemon() - Main Flush Thread

**buf_daemon()** (vfs_bio.c:4566)

Kernel thread that flushes dirty buffers:

```c
static void buf_daemon(void)
{
    for (;;) {
        /* Sleep until work needed */
        tsleep(&bd_request, 0, "psleep", hz);
        
        /* Check if flushing needed */
        if (runningbufspace + dirtykvaspace < lodirtybufspace)
            continue;
        
        /* Flush dirty buffers */
        flushbufqueues(NULL, BQUEUE_DIRTY);
    }
}
```

### flushbufqueues() - Queue Flusher

**flushbufqueues()** (vfs_bio.c:4330)

Scans a buffer queue and flushes dirty buffers:

```c
static int flushbufqueues(struct buf *marker, bufq_type_t q)
{
    int flushed = 0;
    
    /* Scan per-CPU queues */
    for (cpu = 0; cpu < ncpus; cpu++) {
        TAILQ_FOREACH(bp, &bufpcpu[cpu].bufqueues[q], b_freelist) {
            if (bp->b_flags & B_MARKER)
                continue;
            if (bp->b_flags & B_DELWRI) {
                /* Remove from queue */
                bremfree(bp);
                
                /* Try to lock */
                if (BUF_LOCK(bp, LK_EXCLUSIVE | LK_NOWAIT))
                    continue;  /* Skip if locked */
                
                /* Cluster and write */
                cluster_awrite(bp);
                flushed++;
                
                if (flushed >= flushperqueue)
                    break;  /* Flushed enough */
            }
        }
    }
    
    return flushed;
}
```

**Flush triggers:**
- `dirtybufspace > hidirtybufspace` - High watermark exceeded
- System sync operation (sync(2) system call)
- Vnode reclamation (vnode has dirty buffers)
- Filesystem-specific sync (VFS_SYNC)

### VFS_SYNC - Filesystem Sync

**VFS_SYNC()** vnode operation:

Called to sync a filesystem:

```c
int VFS_SYNC(struct mount *mp, int waitfor)
```

**Typical implementation:**

```c
static int myfs_sync(struct mount *mp, int waitfor)
{
    /* Sync inodes */
    myfs_sync_inodes(mp, waitfor);
    
    /* Scan dirty vnodes */
    sync_info.waitfor = waitfor;
    vmntvnodescan(mp, VMSC_GETVP, NULL, myfs_sync_callback, &sync_info);
    
    /* Write superblock */
    myfs_write_superblock(mp);
    
    return 0;
}
```

**waitfor values:**
- `MNT_WAIT`: Wait for all I/O to complete
- `MNT_NOWAIT`: Initiate I/O but don't wait
- `MNT_LAZY`: Lazy sync (metadata only)

## Page Cleaning

### vfs_clean_pages() - Mark Pages Clean

**vfs_clean_pages()** (vfs_bio.c:3980)

Marks VM pages clean after buffer written:

```c
static void vfs_clean_pages(struct buf *bp)
{
    if (bp->b_flags & B_VMIO) {
        for (i = 0; i < bp->b_xio.xio_npages; i++) {
            m = bp->b_xio.xio_pages[i];
            vfs_clean_one_page(bp, i, m);
        }
    }
}
```

**vfs_clean_one_page()** (vfs_bio.c:4002):

```c
static void vfs_clean_one_page(struct buf *bp, int pageno, vm_page_t m)
{
    int soff, eoff;
    
    /* Calculate page-relative dirty range */
    soff = max(bp->b_dirtyoff - pageno * PAGE_SIZE, 0);
    eoff = min(bp->b_dirtyend - pageno * PAGE_SIZE, PAGE_SIZE);
    
    if (eoff > soff) {
        /* Mark page range clean */
        vm_page_set_valid(m, soff, eoff - soff);
        vm_page_clear_dirty(m, soff, eoff - soff);
    }
}
```

### Page Validity

VM pages have validity bits tracking which parts contain valid data:

**vm_page->valid** bitmask:
- One bit per 512-byte sector (DEV_BSIZE)
- `VM_PAGE_BITS_ALL` (0xFF): Entire page valid
- Partial validity supported

**vm_page_set_valid()**: Sets validity bits for byte range

**vm_page_clear_dirty()**: Clears dirty bits for byte range

## KVABIO API

### Overview

KVABIO (Kernel Virtual Address BIO) allows efficient buffer access across CPUs without explicit synchronization.

**Problem**: Regular buffers (b_data) may be accessed via different CPUs:
- Data written on CPU0
- Buffer passed to CPU1
- CPU1 reads stale data from cache

**Solution**: KVABIO API provides:
- Explicit synchronization primitives
- Per-CPU data mapping tracking
- Automatic cache coherency

### KVABIO Functions

**bkvasync()** (vfs_bio.c):

Synchronizes buffer data for current CPU:

```c
void bkvasync(struct buf *bp)
{
    if (bp->b_flags & B_KVABIO) {
        /* Ensure data visible to current CPU */
        cpu_lfence();  /* Load fence */
    }
}
```

**bkvasync_all()** (vfs_bio.c):

Synchronizes buffer data for all CPUs:

```c
void bkvasync_all(struct buf *bp)
{
    if (bp->b_flags & B_KVABIO) {
        /* Flush to all CPUs */
        cpu_sfence();  /* Store fence */
        /* IPI to other CPUs if needed */
    }
}
```

**Usage:**
- Call bkvasync() before reading bp->b_data
- Call bkvasync_all() after writing bp->b_data
- Only needed for B_KVABIO buffers

## Performance Considerations

### Buffer Cache Sizing

**Optimal buffer cache size:**
- Default: ~10% of physical RAM
- Minimum (lobufspace): 4 MB
- Maximum (maxbufspace): Computed from available RAM
- Adjust via sysctl: `vfs.maxbufspace`, `vfs.hibufspace`

**Trade-offs:**
- Larger cache: Better hit rate, less I/O
- Smaller cache: More RAM for VM page cache
- Balance based on workload

### Dirty Buffer Limits

**Configure dirty limits:**
- `vfs.lodirtybufspace`: When to start flushing (default: ~5% RAM)
- `vfs.hidirtybufspace`: Aggressive flushing (default: ~10% RAM)
- `vfs.dirtybufspace`: Current dirty space (read-only)

**Why limit dirty buffers?**
- Prevent memory exhaustion
- Bound data loss on crash
- Ensure write progress
- Avoid sync stalls

### Read-ahead Tuning

**Sequential detection:**
- Tracked via seqcount (0-127)
- Scales read-ahead: seqcount * blksize
- Maximum read-ahead: MAXPHYS (128KB typically)

**Read-ahead benefits:**
- Hides disk latency
- Improves streaming performance
- Minimal overhead for random access

**Disable read-ahead:**
- For random workloads
- Flash storage with fast random access
- Set `vfs.read_max` lower

### Write Clustering

**Enable clustering:**
- Filesystem sets B_CLUSTEROK on buffers
- bdwrite() for delayed writes
- buf_daemon clusters during flush

**Benefits:**
- Reduces write overhead
- Larger I/O sizes
- Better disk scheduling

**When not to cluster:**
- Synchronous writes (bwrite)
- Small files (<128KB)
- Random write patterns

## Error Handling

### I/O Errors

**Error propagation:**

```c
/* I/O completes with error */
biodone() {
    bio->bio_flags |= BIO_ERROR;
    bp->b_error = EIO;  /* Or specific error */
    bp->b_flags |= B_ERROR;
    bufdone(bp);
}

/* Sync I/O: Error returned */
error = biowait(bio, "biord");
if (error)
    return error;

/* Async I/O: Error logged, buffer marked invalid */
biodone() {
    if (bp->b_flags & B_ERROR) {
        bp->b_flags |= B_INVAL;  /* Invalidate */
        /* Error may be logged by filesystem */
    }
}
```

### Retry Strategies

**Filesystem-level retry:**
- VFS layers don't retry automatically
- Filesystem must detect error and retry
- Example: NFS retries on EIO

**User-level retry:**
- read(2)/write(2) return -1 with errno
- Application decides retry policy

## Debugging

### Buffer State Inspection

**DDB commands** (when kernel debugger active):

```
db> show buffer <addr>       # Display buffer state
db> show allbufs             # List all buffers
db> show lockedbufs          # List locked buffers
db> show dirtybufs           # List dirty buffers
```

**Sysctl inspection:**

```sh
# Buffer cache statistics
sysctl vfs.nbuf              # Total buffers
sysctl vfs.bufspace          # Current space used
sysctl vfs.dirtybufspace     # Dirty buffer space
sysctl vfs.dirtybufcount     # Dirty buffer count
sysctl vfs.runningbufspace   # Running I/O space
sysctl vfs.runningbufcount   # Running I/O count

# Tuning parameters
sysctl vfs.maxbufspace       # Max buffer space
sysctl vfs.hibufspace        # High watermark
sysctl vfs.lodirtybufspace   # Dirty low watermark
sysctl vfs.hidirtybufspace   # Dirty high watermark
```

### Common Issues

**Issue: System hangs during sync**
- Cause: Deadlock in buffer allocation
- Debug: Check runningbufspace vs hirunningspace
- Solution: Increase vfs.hirunningspace

**Issue: Poor write performance**
- Cause: Not clustering writes
- Debug: Check if B_CLUSTEROK set on buffers
- Solution: Enable write clustering in filesystem

**Issue: Excessive read-ahead**
- Cause: High seqcount on random workload
- Debug: Monitor vfs.lowmempgallocs
- Solution: Reduce MAXPHYS or tune read-ahead

**Issue: Buffer cache thrashing**
- Cause: Working set larger than cache
- Debug: Monitor vfs.getnewbufcalls
- Solution: Increase vfs.maxbufspace

## Summary

The VFS buffer cache is a sophisticated subsystem providing:

1. **Caching**: Filesystem block caching with LRU eviction
2. **I/O Management**: Sync/async I/O primitives (bread, bwrite, bdwrite)
3. **VM Integration**: Unified buffer/page cache via VMIO
4. **Clustering**: Read-ahead and write clustering for performance
5. **Dirty Tracking**: Write-behind with configurable watermarks
6. **Multi-threading**: Per-CPU queues and dedicated flush threads
7. **Flexibility**: BIO layer enables device stacking and transformation

The buffer cache sits at a critical junction between filesystems, the VM system, and device drivers, providing high-performance cached I/O while maintaining data consistency and integrity.

Key design principles:
- **Lock-free fast paths**: Atomic operations and per-CPU structures
- **Unified caching**: VMIO integrates buffer and page caches
- **Asynchronous I/O**: Pipeline writes, overlap operations
- **Adaptive behavior**: Sequential detection, watermark-based flushing
- **Layered I/O**: BIO translation enables complex storage stacks
