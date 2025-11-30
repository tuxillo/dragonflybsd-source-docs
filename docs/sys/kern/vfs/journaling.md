# VFS Journaling System

## Overview

The DragonFly BSD VFS journaling system provides a flexible infrastructure for recording filesystem operations to a journal stream. This enables features like:

- **Transaction logging** - Record all filesystem changes
- **Replication** - Stream changes to remote systems
- **Crash recovery** - Replay operations after system failures
- **Auditing** - Track all filesystem modifications
- **Two-way acknowledgement** - Full-duplex journaling with commit confirmation

The journaling layer sits between VOP wrappers and the underlying filesystem, transparently intercepting and recording operations before passing them through to the actual filesystem implementation.

**Key components:**
- **Memory FIFO** - Circular buffer for batching journal records
- **Worker threads** - Asynchronous write-out to journal targets
- **Stream records** - Structured format for journal data
- **Transaction IDs** - Sequencing and acknowledgement
- **Subrecords** - Nested transaction structure

**Key files:**
- `sys/kern/vfs_journal.c` - Core journaling infrastructure and FIFO management
- `sys/kern/vfs_jops.c` - Journal VOP implementations
- `sys/sys/journal.h` - Journaling data structures and protocol definitions

## Architecture

### Layered Design

```
User/Kernel VFS calls
        ↓
VOP Wrappers (vfs_vopops.c)
        ↓
Journal Layer (vfs_jops.c) ← If journaling enabled
        ↓
Underlying Filesystem
        ↓
Disk/Storage
```

When journaling is enabled for a mount point:
1. Mount point's `mnt_vn_journal_ops` is set to `journal_vnode_vops`
2. VOP operations are intercepted by journal functions
3. Journal records operation details to memory FIFO
4. Worker thread writes FIFO contents to journal target
5. Operation is passed to underlying filesystem

### Memory FIFO Structure

The memory FIFO is a circular buffer that batches journal records before writing to the target:

```c
struct journal_fifo {
    char *membase;      // Base of circular buffer
    size_t size;        // Total buffer size (power of 2)
    size_t mask;        // Size - 1 (for wrapping)
    int64_t windex;     // Write index (monotonically increasing)
    int64_t rindex;     // Read index (what's been written out)
    int64_t xindex;     // Acknowledgement index (what's been committed)
};
```

**Index relationships:**
- `windex >= rindex >= xindex` (always)
- Available write space: `size - (windex - xindex)`
- Unwritten data: `windex - rindex`
- Unacknowledged data: `rindex - xindex`

**Key properties:**
- Indices never decrease (monotonically increasing)
- Wrapping uses mask: `physicaloffset = index & mask`
- 16-byte alignment for all records
- Incomplete records block worker thread progress

## Journal Records

### Stream Record Structure

Stream records are the fundamental unit of journaling:

```c
struct journal_rawrecbeg {
    u_int16_t begmagic;     // JREC_BEGMAGIC (0x1234) or INCOMPLETE
    u_int16_t streamid;     // Stream ID + control bits
    int32_t recsize;        // Total record size (includes header/trailer)
    int64_t transid;        // Sequence/transaction ID
    // ... payload data ...
};

struct journal_rawrecend {
    u_int16_t endmagic;     // JREC_ENDMAGIC (0xCDEF)
    u_int16_t check;        // Checksum (0 = disabled)
    int32_t recsize;        // Same as rawrecbeg->recsize
};
```

**Record layout:**
```
+-------------------+
| rawrecbeg (16B)   | Header
+-------------------+
| Payload data      | Variable size
| (subrecords)      |
+-------------------+
| rawrecend (8B)    | Trailer
+-------------------+
Total: 16-byte aligned
```

**Magic numbers:**
- `JREC_BEGMAGIC (0x1234)` - Valid record ready to write
- `JREC_INCOMPLETEMAGIC (0xFFFF)` - Reserved but not yet committed
- `JREC_ENDMAGIC (0xCDEF)` - End marker for reverse scanning

### Stream Control Bits

The `streamid` field combines control bits and stream identifier:

```c
#define JREC_STREAMCTL_BEGIN    0x8000  // Start of logical stream
#define JREC_STREAMCTL_END      0x4000  // End of logical stream
#define JREC_STREAMCTL_ABORTED  0x2000  // Stream was aborted
#define JREC_STREAMID_MASK      0x1FFF  // Actual stream ID (bits 0-12)
```

**Stream lifecycle:**
- **Single record:** `BEGIN | END` set (complete transaction in one record)
- **Multi-record:** First has `BEGIN`, intermediate have neither, last has `END`
- **Aborted:** Last record has `ABORTED | END`

### Special Stream IDs

```c
#define JREC_STREAMID_PAD       0x0001  // Padding (FIFO wrap-around)
#define JREC_STREAMID_SYNCPT    0x0000  // Synchronization point
#define JREC_STREAMID_DISCONT   0x0002  // Discontinuity marker
#define JREC_STREAMID_ACK       0x0004  // Acknowledgement record
#define JREC_STREAMID_RESTART   0x0005  // Journal restart marker

// Filesystem operation streams: 0x0100 - 0x1FFF
```

### Subrecords

Within a stream record, operations are broken down into subrecords:

```c
struct journal_subrecord {
    u_int16_t rectype;      // Control bits + type
    int16_t reserved;       // Future use
    int32_t recsize;        // Subrecord size
    // ... type-specific data ...
};
```

**Subrecord control bits:**
```c
#define JMASK_NESTED    0x8000  // Contains nested subrecords
#define JMASK_LAST      0x4000  // Last subrecord in group
```

**Common subrecord types:**
- `JTYPE_SETATTR` - Attribute changes (nested)
- `JTYPE_WRITE` - File write operation (nested)
- `JTYPE_CREATE` - File creation (nested)
- `JTYPE_REMOVE` - File removal (nested)
- `JTYPE_RENAME` - File rename (nested)
- `JTYPE_UNDO` - Undo information (nested)
- `JLEAF_FILEDATA` - File content data (leaf)
- `JLEAF_PATH1/2/3/4` - Pathname components (leaf)
- `JLEAF_UID/GID` - User/group IDs (leaf)

## FIFO Management

### Reservation Process

Located at `sys/kern/vfs_journal.c:496`.

**Function:** `journal_reserve()`

The reservation process ensures thread-safe allocation of FIFO space:

1. **Calculate required space:**
   ```c
   total_bytes = header_size + payload_size + trailer_size;
   aligned_bytes = (total_bytes + 15) & ~15;  // 16-byte align
   ```

2. **Check for wrap-around:**
   ```c
   availtoend = fifo_size - (windex & fifo_mask);
   if (bytes > availtoend) {
       req = bytes + availtoend;  // Need pad record at end
   }
   ```

3. **Wait for space if needed:**
   ```c
   avail = fifo_size - (windex - xindex);
   if (avail < req) {
       jo->flags |= MC_JOURNAL_WWAIT;
       tsleep(&jo->fifo.windex, 0, "jwrite", 0);
   }
   ```

4. **Create pad record if wrapping:**
   - Pad record fills dead space at end of FIFO
   - Has valid transaction ID for sequencing
   - Worker thread skips pad records

5. **Reserve space:**
   ```c
   rawp->begmagic = JREC_INCOMPLETEMAGIC;  // Blocks worker thread
   rawp->recsize = bytes;
   rawp->streamid = streamid | JREC_STREAMCTL_BEGIN;
   rawp->transid = jo->transid;
   windex += aligned_bytes;
   ```

6. **Return pointer to payload area:**
   ```c
   return (rawp + 1);  // Skip header
   ```

**Key insight:** The incomplete magic prevents the worker thread from writing past this record until it's committed, allowing the caller to populate the record at leisure.

### Extension and Truncation

Located at `sys/kern/vfs_journal.c:610`.

**Function:** `journal_extend()`

Streams can be extended after initial reservation:

**Case 1: Simple extension** (no size class change)
```c
if (new_aligned_size == old_aligned_size) {
    rawp->recsize += bytes;  // Just update size
    return (payload + truncbytes);
}
```

**Case 2: FIFO still at our record** (can adjust windex)
```c
if (windex is still at end of our record) {
    windex += (new_size - old_size);
    rawp->recsize += bytes;
    return (payload + truncbytes);
}
```

**Case 3: Must create new stream record**
```c
// Commit current record (marked END)
journal_commit(jo, rawpp, truncbytes, 0);

// Create new continuing record (no BEGIN mark)
rptr = journal_reserve(jo, rawpp, streamid, bytes);
rawp->streamid &= ~JREC_STREAMCTL_BEGIN;
```

This creates a **multi-record stream** where records share the same stream ID but only the first has `BEGIN` and only the last has `END`.

### Commit Process

Located at `sys/kern/vfs_journal.c:712`.

**Function:** `journal_commit()`

Committing a record makes it visible to the worker thread:

1. **Truncate if requested:**
   ```c
   if (bytes >= 0) {
       new_recsize = bytes + header_size + trailer_size;
       new_aligned = (new_recsize + 15) & ~15;
   }
   ```

2. **Handle freed space:**
   - **If windex still at our record:** Back-index windex
   - **Otherwise:** Create pad record in dead space

3. **Fill in trailer:**
   ```c
   rendp = (char *)rawp + aligned_size - sizeof(*rendp);
   rendp->endmagic = JREC_ENDMAGIC;
   rendp->recsize = rawp->recsize;
   rendp->check = 0;  // Checksum (currently disabled)
   ```

4. **Mark stream end if closeout:**
   ```c
   if (closeout)
       rawp->streamid |= JREC_STREAMCTL_END;
   ```

5. **Commit with memory barrier:**
   ```c
   cpu_sfence();  // Ensure trailer written before magic
   rawp->begmagic = JREC_BEGMAGIC;  // Makes record visible
   ```

6. **Wake worker if needed:**
   - If FIFO more than half full
   - If threads waiting for space (`MC_JOURNAL_WWAIT`)

### Abort Process

Located at `sys/kern/vfs_journal.c:678`.

**Function:** `journal_abort()`

Aborts can optimize away uncommitted records:

**Case 1: Can reverse windex** (record at end of FIFO)
```c
if (is_begin && windex == end_of_our_record) {
    windex -= aligned_size;  // Completely remove record
    *rawpp = NULL;
}
```

**Case 2: Must mark as aborted**
```c
else {
    rawp->streamid |= JREC_STREAMCTL_ABORTED;
    journal_commit(jo, rawpp, 0, 1);  // Commit with 0 payload
}
```

## Worker Threads

### Write Worker Thread

Located at `sys/kern/vfs_journal.c:165`.

**Function:** `journal_wthread()`

The write worker drains the FIFO to the journal target:

**Main loop:**
```c
for (;;) {
    // Calculate writable bytes
    bytes = windex - rindex;
    
    // Sleep if nothing to write
    if (bytes == 0) {
        if (stop_requested) break;
        tsleep(&jo->fifo, 0, "jfifo", hz);
        continue;
    }
    
    // Block on incomplete records
    rawp = membase + (rindex & mask);
    if (rawp->begmagic == JREC_INCOMPLETEMAGIC) {
        tsleep(&jo->fifo, 0, "jpad", hz);
        continue;
    }
    
    // Skip pad records
    if (rawp->streamid == JREC_STREAMID_PAD) {
        rindex += aligned_recsize;
        xindex += aligned_recsize;  // (if not full-duplex)
        continue;
    }
    
    // Calculate contiguous writable region
    res = 0;
    avail = fifo_size - (rindex & mask);  // To end of buffer
    while (res < bytes && rawp->begmagic == JREC_BEGMAGIC) {
        res += aligned_recsize;
        if (res >= avail) break;  // Hit end of buffer
        rawp = next_record(rawp);
    }
    
    // Write to target
    rindex += bytes;  // Advance BEFORE write (for ack racing)
    error = fp_write(fp, membase + old_rindex, bytes, &written);
    
    // Advance acknowledgement index (if not full-duplex)
    if (!full_duplex) {
        xindex += bytes;
        wakeup_waiters();
    }
}
```

**Key aspects:**
- Never writes incomplete records (blocks until committed)
- Writes contiguous regions up to buffer wrap
- Advances rindex before writing (allows acks to race)
- Handles full-duplex vs simplex differently

### Read Worker Thread (Full-Duplex)

Located at `sys/kern/vfs_journal.c:301`.

**Function:** `journal_rthread()`

For two-way journaling streams, reads acknowledgements from target:

**Main loop:**
```c
for (;;) {
    if (stop_requested) break;
    
    // Read acknowledgement record
    if (transid == 0) {
        error = fp_read(fp, &ack, sizeof(ack), &count, 1, UIO_SYSSPACE);
        if (error || count != sizeof(ack)) break;
        
        // Validate magic numbers
        if (ack.rbeg.begmagic != JREC_BEGMAGIC) break;
        if (ack.rend.endmagic != JREC_ENDMAGIC) break;
        
        transid = ack.rbeg.transid;
    }
    
    // Check for unacknowledged data
    bytes = rindex - xindex;
    if (bytes == 0) {
        // Unsent data acknowledged - protocol error
        kprintf("warning: unsent data acknowledged\n");
        transid = 0;
        continue;
    }
    
    // Get record at xindex
    rawp = membase + (xindex & mask);
    
    // Advance xindex for all records up to transid
    if (rawp->transid < transid) {
        xindex += aligned_recsize;
        total_acked += aligned_recsize;
        wakeup_waiters();
        continue;
    }
    
    // Found matching transid
    if (rawp->transid == transid) {
        xindex += aligned_recsize;
        total_acked += aligned_recsize;
        wakeup_waiters();
        transid = 0;
        continue;
    }
    
    // Unsent data acknowledged - protocol error
    transid = 0;
}
```

**Key aspects:**
- Target can acknowledge multiple records at once
- Target sends back transaction IDs that are committed
- Advances xindex to free up FIFO space
- Wakes up threads waiting for space

## Journal VOP Operations

The file `sys/kern/vfs_jops.c` implements journal-aware VOP operations that intercept filesystem operations to record them before passing through to the underlying filesystem.

### Operation Interception

When journaling is enabled:

```c
struct vop_ops journal_vnode_vops = {
    .vop_default =      vop_journal_operate_ap,
    .vop_setattr =      journal_setattr,
    .vop_write =        journal_write,
    .vop_fsync =        journal_fsync,
    .vop_ncreate =      journal_ncreate,
    .vop_nremove =      journal_nremove,
    .vop_nrename =      journal_nrename,
    // ... etc
};
```

Each intercepted operation follows this pattern:

1. **Start journal record**
2. **Record UNDO information** (if journaling is reversible)
3. **Call underlying VOP**
4. **Record REDO information** (operation details)
5. **Commit journal record**
6. **Return result**

### Example: journal_write()

Located at `sys/kern/vfs_jops.c:400` (approximate).

**Simplified flow:**
```c
static int
journal_write(struct vop_write_args *ap)
{
    struct mount *mp = ap->a_vp->v_mount;
    struct journal *jo;
    struct jrecord jrec;
    int error;
    
    // For each journal on this mount
    TAILQ_FOREACH(jo, &mp->mnt_jlist, jentry) {
        // Initialize journal record
        jrecord_init(jo, &jrec, JTYPE_WRITE);
        
        // Record UNDO data (old file contents) if reversible
        if (jo->flags & MC_JOURNAL_WANT_REVERSIBLE) {
            jrecord_undo_file(&jrec, ap->a_vp, JRUNDO_FILEDATA,
                            ap->a_uio->uio_offset, 
                            ap->a_uio->uio_resid);
        }
        
        // Record write operation details
        jrecord_write(&jrec, ap->a_vp, ap->a_uio, ap->a_ioflag);
    }
    
    // Call underlying filesystem VOP
    error = vop_write_ap(ap);
    
    // Commit all journal records
    TAILQ_FOREACH(jo, &mp->mnt_jlist, jentry) {
        jrecord_done(&jrec, error);
    }
    
    return error;
}
```

**Key steps:**
1. Loop through all journals on mount point (can have multiple)
2. Create `JTYPE_WRITE` stream record
3. Record UNDO if reversible (old file data)
4. Record REDO (write parameters + new data)
5. Perform actual write via underlying VOP
6. Commit journal records with result

### UNDO Recording

Located at `sys/kern/vfs_jops.c:600` (approximate).

**Function:** `jrecord_undo_file()`

For reversible journals, UNDO information allows replaying backwards:

```c
static void
jrecord_undo_file(struct jrecord *jrec, struct vnode *vp,
                  int jrflags, off_t off, off_t bytes)
{
    struct vattr vat;
    struct uio uio;
    
    // Start UNDO subrecord
    jrecord_push(jrec, JTYPE_UNDO);
    
    // Record file attributes
    if (jrflags & JRUNDO_VATTR) {
        VOP_GETATTR(vp, &vat);
        jrecord_write_vattr(jrec, &vat);
    }
    
    // Record file data
    if (jrflags & JRUNDO_FILEDATA) {
        // Read old file contents
        uio.uio_offset = off;
        uio.uio_resid = bytes;
        VOP_READ(vp, &uio, IO_NODELOCKED, cred);
        
        // Write to journal
        jrecord_write_uio(jrec, &uio);
    }
    
    // End UNDO subrecord
    jrecord_pop(jrec);
}
```

**UNDO flags:**
- `JRUNDO_SIZE` - File size
- `JRUNDO_UID/GID` - Ownership
- `JRUNDO_MODES` - Permissions
- `JRUNDO_MTIME/ATIME/CTIME` - Timestamps
- `JRUNDO_FILEDATA` - File contents
- `JRUNDO_NLINK` - Link count
- `JRUNDO_VATTR` - All vattr fields

### REDO Recording

REDO information describes the operation being performed:

**For JTYPE_WRITE:**
```c
jrecord_push(jrec, JTYPE_WRITE);
jrecord_leaf(jrec, JLEAF_PATH1, pathname, pathlen);
jrecord_leaf(jrec, JLEAF_FILEDATA, data, datalen);
jrecord_leaf(jrec, JLEAF_OFFSET, &offset, sizeof(offset));
jrecord_pop(jrec);
```

**For JTYPE_RENAME:**
```c
jrecord_push(jrec, JTYPE_RENAME);
jrecord_push(jrec, JTYPE_UNDO);
    jrecord_leaf(jrec, JLEAF_PATH1, oldpath, oldlen);
jrecord_pop(jrec);
jrecord_leaf(jrec, JLEAF_PATH1, oldpath, oldlen);
jrecord_leaf(jrec, JLEAF_PATH2, newpath, newlen);
jrecord_pop(jrec);
```

## Journal Management

### Installing a Journal

Located at `sys/kern/vfs_jops.c:250` (approximate).

**Function:** `journal_install_vfs_journal()`

Journals are installed via `mountctl()` system call:

```c
static int
journal_install_vfs_journal(struct mount *mp, struct file *fp,
                           const struct mountctl_install_journal *info)
{
    struct journal *jo;
    
    // Check for duplicate journal ID
    TAILQ_FOREACH(jo, &mp->mnt_jlist, jentry) {
        if (strcmp(jo->id, info->id) == 0)
            return EALREADY;
    }
    
    // Allocate journal structure
    jo = kmalloc(sizeof(*jo), M_JOURNAL, M_WAITOK | M_ZERO);
    
    // Initialize fields
    strlcpy(jo->id, info->id, sizeof(jo->id));
    jo->fp = fp;  // File/socket to write journal to
    jo->flags = info->flags;
    
    // Allocate memory FIFO
    jo->fifo.size = info->fifo_size;
    jo->fifo.mask = jo->fifo.size - 1;
    jo->fifo.membase = kmalloc(jo->fifo.size, M_JFIFO, M_WAITOK);
    
    // Initialize indices
    jo->fifo.windex = 0;
    jo->fifo.rindex = 0;
    jo->fifo.xindex = 0;
    jo->transid = 1;
    
    // Create worker threads
    journal_create_threads(jo);
    
    // Add to mount point's journal list
    TAILQ_INSERT_TAIL(&mp->mnt_jlist, jo, jentry);
    
    return 0;
}
```

**Installation flags:**
- `MC_JOURNAL_WANT_AUDIT` - Audit trail mode
- `MC_JOURNAL_WANT_REVERSIBLE` - Record UNDO information
- `MC_JOURNAL_WANT_FULLDUPLEX` - Two-way acknowledgement

### Journal Lifecycle

**Attach:** `journal_attach(mp)`
- Switches mount point's vnops to `journal_vnode_vops`
- Sets `mp->mnt_vn_journal_ops`

**Install:** `journal_install_vfs_journal()`
- Creates journal structure
- Allocates FIFO
- Starts worker threads
- Adds to `mp->mnt_jlist`

**Operate:** Normal VFS operations are intercepted and journaled

**Detach:** `journal_detach(mp)`
- Stops worker threads
- Flushes FIFO
- Frees resources
- Restores normal vnops

## Transaction Structure

### Nested Subrecords

Journal records use nested subrecord structure:

```
Stream Record (JTYPE_RENAME)
├─ JTYPE_UNDO (nested)
│  ├─ JLEAF_PATH1 (old source path) [leaf]
│  └─ JLEAF_PATH2 (old dest path if exists) [leaf, LAST]
├─ JLEAF_PATH1 (source path) [leaf]
└─ JLEAF_PATH2 (destination path) [leaf, LAST]
```

**Subrecord traversal:**
```c
void traverse_subrecords(char *data, int size) {
    struct journal_subrecord *sub = (void *)data;
    
    while ((char *)sub < data + size) {
        if (sub->rectype & JMASK_NESTED) {
            // Recurse into nested subrecord
            traverse_subrecords(sub + 1, sub->recsize - 8);
        } else {
            // Process leaf subrecord
            process_leaf(sub);
        }
        
        // Check for last subrecord
        if (sub->rectype & JMASK_LAST)
            break;
            
        // Advance to next subrecord
        sub = (char *)sub + sub->recsize;
    }
}
```

### jrecord API

High-level API for building journal records:

**Initialize:**
```c
void jrecord_init(struct journal *jo, struct jrecord *jrec, 
                  int16_t streamid);
```

**Push/pop nested subrecords:**
```c
void jrecord_push(struct jrecord *jrec, int16_t rectype);
void jrecord_pop(struct jrecord *jrec);
```

**Write leaf data:**
```c
void jrecord_leaf(struct jrecord *jrec, int16_t rectype, 
                  void *data, int bytes);
void jrecord_data(struct jrecord *jrec, void *buf, int bytes, int dtype);
```

**Commit:**
```c
void jrecord_done(struct jrecord *jrec, int error);
```

**Example usage:**
```c
struct jrecord jrec;

jrecord_init(jo, &jrec, JTYPE_WRITE);

jrecord_push(&jrec, JTYPE_UNDO);
    jrecord_leaf(&jrec, JLEAF_FILEDATA, oldbuf, oldsize);
jrecord_pop(&jrec);

jrecord_leaf(&jrec, JLEAF_PATH1, path, pathlen);
jrecord_leaf(&jrec, JLEAF_FILEDATA, newbuf, newsize);

jrecord_done(&jrec, error);
```

## Synchronization and Locking

### FIFO Concurrency

The memory FIFO supports concurrent operations:

**Multiple writers:** 
- Each thread reserves its own space via `journal_reserve()`
- Incomplete magic blocks worker thread from writing past incomplete records
- Records can be completed out-of-order
- Worker thread writes in reservation order

**Single writer thread:**
- One worker thread per journal
- Reads from FIFO via rindex
- Blocks on incomplete records

**Acknowledgement:**
- Single reader thread (full-duplex only)
- Advances xindex based on acknowledgements
- Frees up FIFO space

**Wait conditions:**
- Writers wait on `&jo->fifo.windex` when FIFO full (`MC_JOURNAL_WWAIT`)
- Worker wakes writers when space available
- Worker waits on `&jo->fifo` when nothing to write

### Memory Barriers

Critical use of memory barriers for correctness:

**Reserve:**
```c
// Initialize record header and trailer
rawp->begmagic = JREC_INCOMPLETEMAGIC;
rawp->recsize = bytes;
// ... fill in fields ...

cpu_sfence();  // Ensure writes complete before advancing windex
jo->fifo.windex += aligned_bytes;
```

**Commit:**
```c
// Fill in trailer
rendp->endmagic = JREC_ENDMAGIC;
rendp->recsize = rawp->recsize;

cpu_sfence();  // Ensure trailer written before magic
rawp->begmagic = JREC_BEGMAGIC;  // Make visible to worker
```

**Pad record:**
```c
rawp->streamid = JREC_STREAMID_PAD;
rawp->recsize = recsize;
rendp->endmagic = JREC_ENDMAGIC;

cpu_sfence();  // Ensure complete before making visible
rawp->begmagic = JREC_BEGMAGIC;
```

These barriers prevent:
- Worker thread seeing incomplete records
- Reordered writes corrupting record structure
- CPU/compiler optimization breaking protocol

## Journal Targets

### File/Socket Support

Journals can write to:

**Regular files:**
```c
fp_write(jo->fp, buf, size, &written, UIO_SYSSPACE);
```

**Sockets (network journaling):**
- TCP sockets for remote replication
- Can span network boundaries
- Two-way acknowledgement over socket

**Special devices:**
- Raw disk partitions for fast local journaling
- Block devices

### Full-Duplex Journaling

For two-way acknowledgement:

**Setup:**
```c
info->flags |= MC_JOURNAL_WANT_FULLDUPLEX;
journal_install_vfs_journal(mp, fp, info);
```

**Operation:**
- Write worker sends journal records
- Read worker receives acknowledgements
- Target must implement ack protocol
- xindex only advances on ack receipt

**Acknowledgement record format:**
```c
struct journal_ackrecord {
    struct journal_rawrecbeg rbeg;
    int32_t filler0;
    int32_t filler1;
    struct journal_rawrecend rend;
};
```

Target sends back transaction ID when committed to stable storage.

### Restart and Resync

Journals support interruption and restart:

**Restart marker:**
```c
JREC_STREAMID_RESTART  // Marks journal restart after interruption
```

**Resync operation:**
- Target can request resync to transaction ID
- Journal fast-forwards xindex
- Allows recovery after link interruption

**Use cases:**
- Network failure recovery
- Target system restart
- Catching up after outage

## Performance Considerations

### FIFO Sizing

FIFO size affects performance and stall behavior:

**Too small:**
- Frequent stalls waiting for space
- `fifostalls` counter increments
- Threads block in `journal_reserve()`

**Too large:**
- Memory overhead
- Longer recovery window on restart
- Delayed error detection

**Recommended:**
- 1-4 MB for local journaling
- 8-32 MB for network journaling
- Power of 2 for efficient masking

### Batching Efficiency

Worker thread batching reduces overhead:

**Wakeup policy:**
```c
if (fifo > 50% full || waiters_present)
    wakeup(&jo->fifo);
```

**Benefits:**
- Amortizes thread switch overhead
- Better CPU cache utilization
- Reduces syscall/write overhead
- Batches related operations

**Heartbeat:**
- Worker wakes periodically (HZ)
- Flushes small amounts of data
- Prevents indefinite delay

### Zero-Copy Optimization

Journal records are built directly in FIFO:

1. Reserve space in FIFO
2. Write data directly to reserved space
3. Commit when complete
4. Worker writes directly from FIFO to target

No intermediate buffering or copying required.

## Error Handling

### Filesystem Operation Errors

If underlying VOP fails:

```c
error = vop_write_ap(ap);
jrecord_done(&jrec, error);  // Records error in journal
```

Journal records operation and result, even on failure.

### Journal Write Errors

If worker thread encounters write error:

```c
error = fp_write(jo->fp, buf, bytes, &res);
if (error) {
    kprintf("journal_thread(%s) write, error %d\n", jo->id, error);
    // XXX: Error policy TBD
    // Options: pause, abort, mark journal failed
}
```

**Current behavior:** Log error and continue
**Future:** Configurable error policies

### FIFO Overflow

When FIFO fills up:

```c
avail = fifo_size - (windex - xindex);
if (avail < required) {
    jo->flags |= MC_JOURNAL_WWAIT;
    ++jo->fifostalls;
    tsleep(&jo->fifo.windex, 0, "jwrite", 0);
}
```

**Blocking behavior:**
- Thread sleeps until space available
- Worker thread wakes waiters
- `fifostalls` tracks frequency

**Implications:**
- Filesystem operations block
- System slows to journal speed
- Prevents memory exhaustion

## Use Cases

### Replication

Stream filesystem changes to remote system:

1. Install journal with socket to remote host
2. All filesystem operations recorded
3. Remote system applies changes
4. Full-duplex acks ensure durability

**Benefits:**
- Near real-time replication
- Crash recovery via replay
- Bandwidth efficient (operation-level)

### Auditing

Record all filesystem access:

```c
info->flags = MC_JOURNAL_WANT_AUDIT;
```

**Captures:**
- All file creates/deletes
- All writes and modifications
- User credentials
- Timestamps
- Process information

**Use:** Security auditing, compliance

### Reversible Journaling

Enable undo capability:

```c
info->flags = MC_JOURNAL_WANT_REVERSIBLE;
```

**Records:**
- UNDO information (old data)
- REDO information (new data)
- Complete state for rollback

**Use:** Snapshot-like functionality, experimental

### Local Fast Journal

For crash recovery:

1. Journal to fast SSD/NVMe
2. Async write to slower main storage
3. Replay journal on crash
4. Discard journal when committed

**Benefits:**
- Fast write acknowledgement
- Large write coalescing
- Crash consistency

## Debugging

### Statistics

Each journal maintains statistics:

```c
struct journal {
    int64_t total_acked;    // Total bytes acknowledged
    int fifostalls;         // FIFO full stall count
    // ...
};
```

**Access via mountctl:**
```c
MOUNTCTL_STATUS_VFS_JOURNAL
```

### Tracing

Enable debugging output:

```c
#if 1
kprintf("ackskip %08llx/%08llx\n", rawp->transid, transid);
#endif
```

**Traces:**
- Acknowledgement processing
- Record sequencing
- Error conditions

### Common Issues

**FIFO stalls:**
- `fifostalls` counter high
- Increase FIFO size
- Check target write performance

**Incomplete record hangs:**
- Thread crashed while populating record
- Incomplete magic left in FIFO
- Worker thread blocked forever
- Solution: Timeout + recovery logic (TBD)

**Acknowledgement protocol errors:**
- "warning: unsent data acknowledged"
- Target acknowledging wrong transid
- Check target implementation

## Limitations and Future Work

### Current Limitations

1. **MPLOCK dependency:**
   - Worker threads still use MPLOCK
   - Not fully SMP-optimized

2. **Error handling:**
   - Limited error policies
   - No automatic journal failure handling

3. **Checksum disabled:**
   - `check` field in records unused
   - No data integrity verification

4. **No encryption:**
   - All data in clear text
   - Security via transport layer only

### Planned Enhancements

From `vfs_journal.c:35-60` comments:

1. **Two-way acknowledgement:**
   - Transaction ID acknowledgement (partially implemented)
   - Explicit and implicit ack schemes
   - Resynchronization support
   - Restart after interruption

2. **Swap space spooling:**
   - Use swap to absorb long interruptions
   - Prevent slow links from blocking local ops
   - Larger buffer capacity

3. **Per-CPU FIFOs:**
   - Remove locking requirements
   - Better SMP scalability
   - Reduce contention

4. **Filesystem integration:**
   - Allow filesystems to use journal layer directly
   - Avoid rolling their own journaling
   - Leverage kernel infrastructure

## Summary

The VFS journaling system provides a sophisticated infrastructure for recording filesystem operations. Key aspects:

**Architecture:**
- Interception layer between VOP wrappers and filesystem
- Memory FIFO batches records before writing
- Asynchronous worker threads for write-out
- Optional two-way acknowledgement

**Record structure:**
- Stream records with headers/trailers
- Nested subrecord hierarchy
- Transaction IDs for sequencing
- Extensible operation types

**Concurrency:**
- Lock-free reservation with incomplete magic
- Multiple writers, single worker thread
- Memory barriers for correctness
- Wait/wakeup for flow control

**Features:**
- Multiple journals per mount point
- Full-duplex acknowledgement
- Reversible journals (UNDO)
- Network and local targets

**Use cases:**
- Replication to remote systems
- Security auditing trails
- Crash recovery journals
- Experimental undo functionality

The journaling system is mature but retains areas for optimization, particularly in SMP scalability and error handling sophistication.

**Related documentation:**
- [VFS Operations](vfs-operations.md) - VOP dispatch mechanism
- [Buffer Cache](buffer-cache.md) - Block I/O infrastructure
- [Mounting](mounting.md) - Mount point management
