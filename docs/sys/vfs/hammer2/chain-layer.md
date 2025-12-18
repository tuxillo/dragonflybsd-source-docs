# HAMMER2 Chain Layer

!!! note "Documentation Status"
    This page documents the chain layer based on `hammer2_chain.c` and `hammer2.h`.

## Overview

The chain layer is HAMMER2's central abstraction for managing block references in memory. Every on-disk blockref is represented in memory as a **chain structure** (`hammer2_chain_t`). Chains form a cached, in-memory representation of the filesystem's block topology and serve as the primary interface between the VFS layer and the underlying storage.

Key responsibilities of the chain layer:

- **Topology management**: Chains organize blockrefs into a tree structure using red-black trees
- **Reference counting**: Chains track references to prevent premature deallocation
- **Locking**: Chains provide mutex-based locking for concurrent access control
- **Data resolution**: Chains manage loading and caching of block data from disk
- **Copy-on-write**: Chains implement COW semantics for modifications
- **Flush integration**: Chains track modification state for the flush subsystem

Source files:

- `sys/vfs/hammer2/hammer2.h` — Structure definitions and constants
- `sys/vfs/hammer2/hammer2_chain.c` — Chain operations implementation

## Chain Structure

### hammer2_chain_t

The `hammer2_chain_t` structure is the primary in-memory representation of any media object (volume header, inode, indirect block, data block, freemap node, etc.).

```c
struct hammer2_chain {
    hammer2_mtx_t           lock;           /* exclusive/shared mutex */
    hammer2_chain_core_t    core;           /* embedded core (rbtree, etc.) */
    RB_ENTRY(hammer2_chain) rbnode;         /* linkage in parent's rbtree */
    hammer2_blockref_t      bref;           /* block reference (128 bytes) */
    struct hammer2_chain    *parent;        /* parent chain */
    struct hammer2_dev      *hmp;           /* device mount point */
    struct hammer2_pfs      *pmp;           /* PFS mount or super-root */

    struct lock             diolk;          /* xop focus interlock */
    hammer2_io_t            *dio;           /* physical data buffer */
    hammer2_media_data_t    *data;          /* data pointer shortcut */
    u_int                   bytes;          /* physical data size */
    u_int                   flags;          /* chain state flags */
    u_int                   refs;           /* reference count */
    u_int                   lockcnt;        /* lock nesting count */
    int                     error;          /* on-lock data error state */
    int                     cache_index;    /* heuristic for faster lookup */
};
```

*Source: `hammer2.h:324-342`*

#### Field Descriptions

| Field | Description |
|-------|-------------|
| `lock` | Mutex for exclusive or shared locking of the chain |
| `core` | Embedded structure containing the RB-tree of child chains |
| `rbnode` | Red-black tree linkage for insertion into parent's child tree |
| `bref` | The 128-byte block reference copied from or destined for media |
| `parent` | Pointer to the parent chain (NULL for root chains) |
| `hmp` | Pointer to the device mount structure |
| `pmp` | Pointer to the PFS mount (NULL for super-root chains) |
| `diolk` | Lock for XOP (cross-cluster operation) focus interlock |
| `dio` | Device I/O structure wrapping the buffer cache |
| `data` | Direct pointer to the chain's data (shortcut through dio) |
| `bytes` | Size of the data in bytes (derived from bref radix) |
| `flags` | State flags (MODIFIED, DELETED, ONFLUSH, etc.) |
| `refs` | Reference count preventing deallocation |
| `lockcnt` | Count of active locks (supports lock nesting) |
| `error` | Error code set during lock/data resolution |
| `cache_index` | Heuristic index to speed up repeated lookups |

### hammer2_chain_core_t

The `hammer2_chain_core_t` structure is embedded within each chain and manages the chain's children:

```c
struct hammer2_chain_core {
    hammer2_spin_t          spin;           /* spinlock for rbtree access */
    struct hammer2_reptrack *reptrack;      /* parent replacement tracking */
    struct hammer2_chain_tree rbtree;       /* RB-tree of child chains */
    int                     live_zero;      /* blockref array optimization */
    u_int                   live_count;     /* count of live (non-deleted) children */
    u_int                   chain_count;    /* total children (live + deleted) */
    int                     generation;     /* generation number for iteration */
};
```

*Source: `hammer2.h:238-246`*

| Field | Description |
|-------|-------------|
| `spin` | Spinlock protecting access to the RB-tree |
| `reptrack` | Linked list for tracking parent replacement during deletion |
| `rbtree` | Red-black tree containing all in-memory child chains |
| `live_zero` | Optimization: index beyond which all blockrefs are empty |
| `live_count` | Number of non-deleted chains in the tree |
| `chain_count` | Total number of chains (including deleted) in the tree |
| `generation` | Incremented on insertions; used to detect iteration races |

## Chain Flags

Chain flags indicate the current state of a chain. Multiple flags can be set simultaneously.

### Core State Flags

| Flag | Value | Description |
|------|-------|-------------|
| `HAMMER2_CHAIN_MODIFIED` | 0x00000001 | Chain data has been modified; requires flush |
| `HAMMER2_CHAIN_ALLOCATED` | 0x00000002 | Chain was kmalloc'd (vs. static) |
| `HAMMER2_CHAIN_DESTROY` | 0x00000004 | Chain should be destroyed when possible |
| `HAMMER2_CHAIN_DEDUPABLE` | 0x00000008 | Chain is registered for deduplication |
| `HAMMER2_CHAIN_DELETED` | 0x00000010 | Chain has been deleted |
| `HAMMER2_CHAIN_INITIAL` | 0x00000020 | Chain is newly created, data is all-zeros |
| `HAMMER2_CHAIN_UPDATE` | 0x00000040 | Parent's blockref needs update |

*Source: `hammer2.h:375-381`*

### Flush and Topology Flags

| Flag | Value | Description |
|------|-------|-------------|
| `HAMMER2_CHAIN_NOTTESTED` | 0x00000080 | CRC has not been generated yet |
| `HAMMER2_CHAIN_TESTEDGOOD` | 0x00000100 | CRC has been tested and is good |
| `HAMMER2_CHAIN_ONFLUSH` | 0x00000200 | Chain is on the flush list |
| `HAMMER2_CHAIN_VOLUMESYNC` | 0x00000800 | Needs volume header sync |
| `HAMMER2_CHAIN_COUNTEDBREFS` | 0x00002000 | Block table stats have been counted |
| `HAMMER2_CHAIN_ONRBTREE` | 0x00004000 | Chain is in parent's RB-tree |
| `HAMMER2_CHAIN_RELEASE` | 0x00020000 | Don't keep chain cached after unlock |
| `HAMMER2_CHAIN_BLKMAPPED` | 0x00040000 | Chain is present in parent's blockmap |
| `HAMMER2_CHAIN_BLKMAPUPD` | 0x00080000 | Blockmap entry needs updating |
| `HAMMER2_CHAIN_PFSBOUNDARY` | 0x00400000 | Chain is a PFS root boundary |

*Source: `hammer2.h:382-399`*

### Flush Mask

The flush mask combines flags that indicate a chain needs attention from the flush subsystem:

```c
#define HAMMER2_CHAIN_FLUSH_MASK    (HAMMER2_CHAIN_MODIFIED |
                                     HAMMER2_CHAIN_UPDATE |
                                     HAMMER2_CHAIN_ONFLUSH |
                                     HAMMER2_CHAIN_DESTROY)
```

*Source: `hammer2.h:401-404`*

## Error Codes

HAMMER2 uses its own error code system that can be ORed together:

| Error Code | Value | Description |
|------------|-------|-------------|
| `HAMMER2_ERROR_NONE` | 0x00000000 | No error |
| `HAMMER2_ERROR_EIO` | 0x00000001 | Device I/O error |
| `HAMMER2_ERROR_CHECK` | 0x00000002 | Checksum verification failed |
| `HAMMER2_ERROR_INCOMPLETE` | 0x00000004 | Cluster incomplete or parent error |
| `HAMMER2_ERROR_DEPTH` | 0x00000008 | Temporary recursion depth limit |
| `HAMMER2_ERROR_BADBREF` | 0x00000010 | Illegal block reference |
| `HAMMER2_ERROR_ENOSPC` | 0x00000020 | No space for allocation |
| `HAMMER2_ERROR_ENOENT` | 0x00000040 | Entry not found |
| `HAMMER2_ERROR_ENOTEMPTY` | 0x00000080 | Directory not empty |
| `HAMMER2_ERROR_EAGAIN` | 0x00000100 | Retry operation |
| `HAMMER2_ERROR_EOF` | 0x00002000 | End of scan |

*Source: `hammer2.h:426-445`*

## Reference Counting

Chains use reference counting to manage their lifetime. A chain cannot be freed while it has outstanding references.

### hammer2_chain_ref()

Adds a reference to a chain:

```c
void hammer2_chain_ref(hammer2_chain_t *chain);
```

- Atomically increments `chain->refs`
- Can be called with spinlocks held
- Chain must already have at least one reference

*Source: `hammer2_chain.c:257-263`*

### hammer2_chain_drop()

Releases a reference:

```c
void hammer2_chain_drop(hammer2_chain_t *chain);
```

- Atomically decrements `chain->refs`
- On 1→0 transition, attempts to disassociate and free the chain
- Recursively drops the parent if the chain was the last child
- The chain cannot be freed if:
    - It has children in its RB-tree
    - It is flagged MODIFIED or UPDATE
    - It is still connected to a parent

*Source: `hammer2_chain.c:345-368`*

### Hold/Unhold Operations

For holding chain data across unlock operations:

| Function | Description |
|----------|-------------|
| `hammer2_chain_ref_hold()` | Ref and increment lockcnt to hold data |
| `hammer2_chain_unhold()` | Decrement lockcnt, may need to reacquire lock |
| `hammer2_chain_drop_unhold()` | Combined unhold and drop |
| `hammer2_chain_rehold()` | Lock shared, increment lockcnt, unlock |

*Source: `hammer2_chain.c:272-426`*

## Locking Model

Chains support both exclusive and shared locking through the `hammer2_chain_lock()` and `hammer2_chain_unlock()` functions.

### Data Resolution Modes

When locking a chain, you specify how data should be resolved:

| Mode | Value | Description |
|------|-------|-------------|
| `HAMMER2_RESOLVE_NEVER` | 1 | Do not resolve data (avoid buffer aliasing) |
| `HAMMER2_RESOLVE_MAYBE` | 2 | Resolve metadata but not bulk data |
| `HAMMER2_RESOLVE_ALWAYS` | 3 | Always resolve and load data |

*Source: `hammer2.h:497-500`*

### Lock Flags

| Flag | Value | Description |
|------|-------|-------------|
| `HAMMER2_RESOLVE_SHARED` | 0x10 | Request shared (read) lock |
| `HAMMER2_RESOLVE_LOCKAGAIN` | 0x20 | Another shared lock (nesting) |
| `HAMMER2_RESOLVE_NONBLOCK` | 0x80 | Non-blocking lock attempt |

*Source: `hammer2.h:502-505`*

### hammer2_chain_lock()

```c
int hammer2_chain_lock(hammer2_chain_t *chain, int how);
```

Locks a referenced chain and optionally resolves its data:

- **RESOLVE_NEVER**: Does not load data; `chain->data` remains NULL
- **RESOLVE_MAYBE**: Loads metadata (inodes, indirect blocks) but not DATA blocks
- **RESOLVE_ALWAYS**: Always loads data from disk if not already present
- Sets `chain->error` on I/O or checksum failure
- Returns 0 on success, EAGAIN if NONBLOCK specified and lock unavailable
- Lock can recurse; `lockcnt` tracks nesting depth

*Source: `hammer2_chain.c:787-859`*

### hammer2_chain_unlock()

```c
void hammer2_chain_unlock(hammer2_chain_t *chain);
```

Unlocks a chain:

- Decrements `lockcnt`
- On last unlock (lockcnt 1→0), may drop data reference
- Data is dropped unless chain has MODIFIED flag set
- Releases the underlying mutex

*Source: `hammer2_chain.c:860-920`*

## Chain Lifecycle

### Allocation

```c
hammer2_chain_t *hammer2_chain_alloc(hammer2_dev_t *hmp, hammer2_pfs_t *pmp,
                                      hammer2_blockref_t *bref);
```

Allocates a new disconnected chain:

1. Calculates `bytes` from the blockref's radix field
2. Allocates memory with `kmalloc_obj()`
3. Initializes the chain structure:
    - Copies the blockref to `chain->bref`
    - Sets `refs = 1`
    - Sets `flags = HAMMER2_CHAIN_ALLOCATED`
    - Initializes mutex, spinlock, and RB-tree
4. Returns a referenced but **unlocked** chain

*Source: `hammer2_chain.c:177-237`*

### Initialization

```c
void hammer2_chain_init(hammer2_chain_t *chain);
```

Initializes chain synchronization primitives:

- Initializes the RB-tree (`RB_INIT`)
- Initializes the chain mutex
- Initializes the core spinlock
- Initializes the DIO interlock

*Source: `hammer2_chain.c:242-249`*

### Insertion

```c
static int hammer2_chain_insert(hammer2_chain_t *parent, hammer2_chain_t *chain,
                                 int flags, int generation);
```

Inserts a chain into a parent's RB-tree:

- Acquires parent's spinlock if `HAMMER2_CHAIN_INSERT_SPIN` is set
- Checks for race conditions if `HAMMER2_CHAIN_INSERT_RACE` is set
- Inserts into parent's `core.rbtree`
- Sets `HAMMER2_CHAIN_ONRBTREE` flag
- Updates `chain_count` and `generation`
- Increments `live_count` if `HAMMER2_CHAIN_INSERT_LIVE` is set

*Source: `hammer2_chain.c:290-332`*

### Deallocation

When `refs` drops to 0, `hammer2_chain_lastdrop()` handles cleanup:

1. Acquires chain's spinlock
2. Checks if chain can be freed:
    - Must not have MODIFIED or UPDATE flags (if parent exists)
    - Must not have children in RB-tree
3. Removes chain from parent's RB-tree if present
4. Frees the chain memory
5. May recursively drop parent

*Source: `hammer2_chain.c:450-699`*

## Tree Traversal

### Lookup Initialization

```c
hammer2_chain_t *hammer2_chain_lookup_init(hammer2_chain_t *parent, int flags);
void hammer2_chain_lookup_done(hammer2_chain_t *parent);
```

Bracket a series of lookups:

- `lookup_init`: Refs and locks the parent
- `lookup_done`: Unlocks and drops the parent

*Source: `hammer2_chain.c:2113-2133`*

### hammer2_chain_lookup()

```c
hammer2_chain_t *hammer2_chain_lookup(hammer2_chain_t **parentp, hammer2_key_t *key_nextp,
                                       hammer2_key_t key_beg, hammer2_key_t key_end,
                                       int *errorp, int flags);
```

Looks up the first chain whose key range overlaps `[key_beg, key_end]`:

1. Counts blockrefs if not already counted (`COUNTEDBREFS`)
2. Acquires parent's spinlock
3. Calls `hammer2_combined_find()` to search both:
    - The in-memory RB-tree of child chains
    - The on-disk blockref array
4. If found in blockref but not in memory, creates chain with `hammer2_chain_get()`
5. Handles MATCHIND flag to return indirect blocks
6. Returns locked chain, sets `*key_nextp` for iteration

*Source: `hammer2_chain.c:2339-2600`*

### Lookup Flags

| Flag | Description |
|------|-------------|
| `HAMMER2_LOOKUP_NODATA` | Don't resolve data (leave NULL) |
| `HAMMER2_LOOKUP_NODIRECT` | Don't return inode for offset 0 in DIRECTDATA mode |
| `HAMMER2_LOOKUP_SHARED` | Use shared lock |
| `HAMMER2_LOOKUP_MATCHIND` | Allow returning indirect blocks |
| `HAMMER2_LOOKUP_ALWAYS` | Always resolve data |

*Source: `hammer2.h:473-480`*

### hammer2_chain_next()

```c
hammer2_chain_t *hammer2_chain_next(hammer2_chain_t **parentp, hammer2_chain_t *chain,
                                     hammer2_key_t *key_nextp,
                                     hammer2_key_t key_beg, hammer2_key_t key_end,
                                     int *errorp, int flags);
```

Continues iteration after `hammer2_chain_lookup()`:

- Unlocks and drops the previous chain
- Uses `*key_nextp` to find the next element
- Returns NULL with `HAMMER2_ERROR_EOF` when done

*Source: `hammer2_chain.c:2690-2780`*

### hammer2_chain_scan()

```c
int hammer2_chain_scan(hammer2_chain_t *parent, hammer2_chain_t **chainp,
                        hammer2_blockref_t *bref, int *firstp, int flags);
```

Raw scan for iterating all children:

- Does not seek to a specific key
- Fills in `bref` with the current blockref
- Only instantiates chains for recursive types (INDIRECT, INODE, etc.)
- Returns `HAMMER2_ERROR_EOF` when exhausted

*Source: `hammer2_chain.c:2820-3020`*

## Modification Operations

### hammer2_chain_modify()

```c
int hammer2_chain_modify(hammer2_chain_t *chain, hammer2_tid_t mtid,
                          hammer2_off_t dedup_off, int flags);
```

Marks a chain as modified, implementing copy-on-write:

1. Loads existing data if needed (unless OPTDATA flag)
2. If not already MODIFIED:
    - Sets MODIFIED flag
    - Determines if COW is required (checks overwrite-in-place eligibility)
3. Sets UPDATE flag for parent blockref update
4. Acquires `diolk` for XOP interlock
5. If new allocation needed:
    - Calls `hammer2_freemap_alloc()` for new block
    - Copies old data to new block
    - Clears DEDUPABLE flag
6. If `dedup_off` specified:
    - Uses dedup block instead of new allocation
    - Clears MODIFIED, sets DEDUPABLE

**Overwrite-in-place**: Allowed when:

- Chain is DATA or DIRENT type
- Check mode is NONE
- `modify_tid` is beyond the last snapshot

*Source: `hammer2_chain.c:1436-1750`*

### hammer2_chain_resize()

```c
int hammer2_chain_resize(hammer2_chain_t *chain, hammer2_tid_t mtid,
                          hammer2_off_t dedup_off, int nradix, int flags);
```

Resizes a chain's physical storage:

- Only DATA, INDIRECT, and DIRENT blocks can be resized
- Calls `hammer2_chain_modify()` first
- Allocates new storage with `hammer2_freemap_alloc()`
- Updates `chain->bytes`
- Caller must copy data if needed

*Source: `hammer2_chain.c:1339-1407`*

## Chain Creation and Deletion

### hammer2_chain_create()

```c
int hammer2_chain_create(hammer2_chain_t **parentp, hammer2_chain_t **chainp,
                          hammer2_pfs_t *pmp, int methods,
                          hammer2_key_t key, int keybits,
                          int type, size_t bytes,
                          hammer2_tid_t mtid, hammer2_off_t dedup_off, int flags);
```

Creates a new chain or reattaches an existing one:

1. If `*chainp` is NULL, allocates a new chain with INITIAL flag
2. Ensures parent has room for new child:
    - If `live_count == count`, creates indirect block
3. Inserts chain into parent's RB-tree
4. Calls `hammer2_chain_modify()` for newly allocated chains
5. Sets UPDATE flag for reconnected chains
6. Calls `hammer2_chain_setflush()` on parent

**Indirect block creation**: When a parent's blockref array is full, `hammer2_chain_create_indirect()` is called to:

1. Allocate an indirect block
2. Move some children to the indirect block
3. Return the appropriate parent for the new chain

*Source: `hammer2_chain.c:3070-3388`*

### hammer2_chain_delete()

```c
void hammer2_chain_delete(hammer2_chain_t *parent, hammer2_chain_t *chain,
                           hammer2_tid_t mtid, int flags);
```

Deletes a chain from the topology:

1. Sets DELETED flag
2. Removes chain from parent's RB-tree
3. Removes blockmap entry from parent (if BLKMAPPED)
4. Decrements parent's `live_count`
5. If `HAMMER2_DELETE_PERMANENT`:
    - Marks storage for deallocation via freemap

*Source: `hammer2_chain.c:3640-3680`*

### hammer2_chain_rename()

```c
void hammer2_chain_rename(hammer2_chain_t **parentp, hammer2_chain_t *chain,
                           hammer2_tid_t mtid, int flags);
```

Moves a chain to a new parent:

- Chain must already be disconnected (deleted or never attached)
- Calls `hammer2_chain_create()` to insert under new parent
- Sets UPDATE and ONFLUSH flags

*Source: `hammer2_chain.c:3415-3461`*

## Flush Integration

### hammer2_chain_setflush()

```c
void hammer2_chain_setflush(hammer2_chain_t *chain);
```

Marks a chain and its ancestors for flushing:

1. Sets ONFLUSH flag on chain
2. Walks up to parent, setting ONFLUSH on each
3. Stops at inode boundaries (flush inflection points)
4. Inode chains connect different flush domains

The flusher uses ONFLUSH to efficiently locate modified chains via top-down recursion.

*Source: `hammer2_chain.c:146-165`*

### Flush-Related Flags

| Flag | Purpose |
|------|---------|
| `MODIFIED` | Chain data was modified, needs writing |
| `UPDATE` | Parent blockref needs updating |
| `ONFLUSH` | Chain is on the flush recursion path |
| `BLKMAPPED` | Chain exists in parent's on-disk blockmap |
| `BLKMAPUPD` | Blockmap entry needs update (bref changed) |

## Parent Access

### hammer2_chain_getparent()

```c
hammer2_chain_t *hammer2_chain_getparent(hammer2_chain_t *chain, int flags);
```

Returns a locked parent while keeping chain locked:

- Handles lock order reversal (must unlock child before locking parent)
- Re-locks child after acquiring parent
- Handles races where parent changes during unlock window

*Source: `hammer2_chain.c:2149-2185`*

### hammer2_chain_repparent()

```c
hammer2_chain_t *hammer2_chain_repparent(hammer2_chain_t **chainp, int flags);
```

Returns parent while dropping the chain:

- Uses `reptrack` mechanism to follow parent if it changes
- Handles complex deletion scenarios during indirect block cleanup
- More complex than `getparent()` but handles unstable chains

*Source: `hammer2_chain.c:2200-2293`*

## RB-Tree Organization

Chains are organized in a red-black tree within their parent, keyed by their blockref's key and keybits:

```c
int hammer2_chain_cmp(hammer2_chain_t *chain1, hammer2_chain_t *chain2);
```

The comparison function:

1. Calculates key range for each chain: `[key, key + (1 << keybits) - 1]`
2. Returns -1 if chain1 is fully left of chain2
3. Returns +1 if chain1 is fully right of chain2
4. Returns 0 for overlap (should not happen in normal operation)

This allows efficient range-based lookups and ensures children don't overlap.

*Source: `hammer2_chain.c:96-118`*

## Combined Find

The `hammer2_combined_find()` function merges results from:

1. **In-memory chains**: Searched via RB-tree scan
2. **On-disk blockrefs**: Searched via linear scan of blockref array

This is necessary because:

- Not all on-disk blockrefs have in-memory chains
- In-memory chains may be newly created (not yet on disk)
- In-memory chains may be deleted (still on disk until flushed)

The combined find returns the best match considering both sources.

*Source: `hammer2_chain.c:1900-2030`*

## See Also

- [HAMMER2 Overview](index.md)
- [On-Disk Format](on-disk-format.md) — Underlying block references
- [Inode Layer](inode-layer.md) — Higher-level inode abstraction
- [Flush and Sync](flush-sync.md) — How chains are flushed to disk
- [XOP System](xop-system.md) — Cross-cluster operations using chains
