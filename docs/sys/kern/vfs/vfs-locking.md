# VFS Vnode Locking and Lifecycle

## Overview

The DragonFly BSD vnode locking subsystem (`vfs_lock.c`) manages vnode lifecycle states, reference counting, and synchronization. Unlike traditional BSD systems that use simple reference counts, DragonFly implements a sophisticated state machine with multiple vnode states and specialized locking primitives designed for SMP scalability.

The system provides:

- **State-based lifecycle management** - Vnodes transition through CACHED, ACTIVE, INACTIVE, and DYING states
- **Two-tier reference counting** - Regular refs (`v_refcnt`) and auxiliary refs (`v_auxrefs`)
- **Per-CPU vnode lists** - Reduces lock contention by partitioning vnodes across CPUs
- **Lockless fast paths** - Many operations use atomic operations without acquiring locks
- **VX locking** - Special exclusive locks for reclamation and deactivation

**Key files:**
- `sys/kern/vfs_lock.c` - Vnode locking, state transitions, and recycling
- `sys/kern/vfs_vnops.c` - Standard vnode lock functions (`vn_lock`, `vn_unlock`)
- `sys/sys/vnode.h` - Vnode structure and state definitions

## Vnode States

Vnodes exist in one of four states, managed through the `v_state` field:

```
                    ┌──────────────────────────────────────┐
                    │                                      │
                    v                                      │
    ┌─────────┐  vget()   ┌─────────┐  vrele()   ┌──────────┐
    │ VS_CACHED├─────────►│VS_ACTIVE├──────────►│VS_INACTIVE│
    └─────────┘           └─────────┘            └──────────┘
         ▲                     │                      │
         │                     │                      │
         │    vget()           │ vrele()              │ reclaim
         └─────────────────────┘                      │
                                                      v
                                                ┌──────────┐
                                                │ VS_DYING │
                                                └──────────┘
                                                      │
                                                      v
                                                   kfree()
```

### State Definitions

| State | Value | Description |
|-------|-------|-------------|
| `VS_CACHED` | 0 | Vnode exists but has no references; eligible for reuse |
| `VS_ACTIVE` | 1 | Vnode is actively referenced and in use |
| `VS_INACTIVE` | 2 | Vnode has been deactivated; on inactive list awaiting reclamation |
| `VS_DYING` | 3 | Vnode is being destroyed; removed from all lists |

### State Transition Locking Requirements

From `vfs_lock.c:38-53`:

```
INACTIVE -> CACHED|DYING    vx_lock(excl) + vi->spin
DYING    -> CACHED          vx_lock(excl)
ACTIVE   -> INACTIVE        (none) + v_spin + vi->spin
INACTIVE -> ACTIVE          vn_lock(any) + v_spin + vi->spin
CACHED   -> ACTIVE          vn_lock(any) + v_spin + vi->spin
```

Key observations:
- Transitions **into** ACTIVE can use shared locks
- Transitions **into** CACHED or DYING require exclusive VX locks
- The `v_spin` spinlock protects per-vnode state
- The `vi->spin` spinlock protects the per-CPU vnode lists

## Reference Counting

DragonFly uses a sophisticated reference counting scheme with special flags embedded in the reference count field.

### Reference Count Fields

```c
struct vnode {
    int v_refcnt;      /* vget/vput refs + flags */
    int v_auxrefs;     /* vhold/vdrop refs */
    // ...
};
```

### Reference Count Flags

From `sys/vnode.h:252-256`:

```c
#define VREF_TERMINATE  0x80000000  /* termination in progress */
#define VREF_FINALIZE   0x40000000  /* deactivate on last vrele */
#define VREF_MASK       0xBFFFFFFF  /* includes VREF_TERMINATE */

#define VREFCNT(vp)     ((int)((vp)->v_refcnt & VREF_MASK))
```

| Flag | Purpose |
|------|---------|
| `VREF_TERMINATE` | Set when vnode is undergoing termination; prevents reactivation |
| `VREF_FINALIZE` | Requests deactivation on the 1->0 ref transition |
| `VREF_MASK` | Extracts actual reference count (includes TERMINATE bit) |

### Regular References (vref/vrele)

**`vref(vp)`** - Add a reference to an active vnode:

```c
void vref(struct vnode *vp)
{
    KASSERT((VREFCNT(vp) > 0 && vp->v_state != VS_INACTIVE),
            ("vref: bad refcnt %08x %d", vp->v_refcnt, vp->v_state));
    atomic_add_int(&vp->v_refcnt, 1);
}
```

- Caller must already hold a reference
- Cannot be called on inactive vnodes (use `vget()` instead)
- Lock-free atomic operation

**`vrele(vp)`** - Release a reference:

The 1->0 transition is critical and handles finalization:

```c
void vrele(struct vnode *vp)
{
    // For refs > 1: simple atomic decrement
    if ((count & VREF_MASK) > 1) {
        atomic_fcmpset_int(&vp->v_refcnt, &count, count - 1);
        return;
    }
    
    // For 1->0 with VREF_FINALIZE: trigger termination
    if (count & VREF_FINALIZE) {
        vx_lock(vp);
        if (atomic_fcmpset_int(&vp->v_refcnt, &count, VREF_TERMINATE)) {
            vnode_terminate(vp);  // Calls VOP_INACTIVE, moves to inactive list
        }
        vx_unlock(vp);
    } else {
        // Simple 1->0: vnode becomes cached
        atomic_fcmpset_int(&vp->v_refcnt, &count, 0);
        atomic_add_int(&mycpu->gd_cachedvnodes, 1);
    }
}
```

### Auxiliary References (vhold/vdrop)

Auxiliary references prevent vnode destruction but don't affect state:

```c
void vhold(struct vnode *vp)
{
    atomic_add_int(&vp->v_auxrefs, 1);
}

void vdrop(struct vnode *vp)
{
    atomic_add_int(&vp->v_auxrefs, -1);
}
```

Use cases:
- Namecache entries holding references to vnodes
- VM objects associated with vnodes
- Temporary holds during complex operations

A vnode cannot be freed (`kfree()`'d) while `v_auxrefs > 0`.

## VX Locking

VX locks are special exclusive locks used for vnode reclamation and deactivation. They combine the standard vnode lock with a spin lock update.

### VX Lock Functions

```c
void vx_lock(struct vnode *vp)
{
    lockmgr(&vp->v_lock, LK_EXCLUSIVE);
    spin_lock_update_only(&vp->v_spin);
}

void vx_unlock(struct vnode *vp)
{
    spin_unlock_update_only(&vp->v_spin);
    lockmgr(&vp->v_lock, LK_RELEASE);
}
```

The `spin_lock_update_only()` is a special spinlock mode that:
- Prevents readers from proceeding
- Allows the holder to make atomic state changes
- Is lighter weight than a full exclusive spinlock

### VX vs VN Locking

| Aspect | VN Lock (`vn_lock`) | VX Lock (`vx_lock`) |
|--------|---------------------|---------------------|
| Lock type | Can be shared or exclusive | Always exclusive |
| Spin lock | Not held | Holds `v_spin` in update mode |
| Use case | Normal vnode operations | Reclamation, deactivation |
| Reactivation | Allowed | Not applicable |

### Downgrading VX to VN

After allocating a new vnode, callers typically downgrade from VX to VN:

```c
void vx_downgrade(struct vnode *vp)
{
    spin_unlock_update_only(&vp->v_spin);
    // Lock remains EXCLUSIVE, just without spin update mode
}
```

## Vnode Acquisition (vget)

The `vget()` function acquires a reference and lock on a vnode, potentially reactivating it:

```c
int vget(struct vnode *vp, int flags)
{
    // 1. Add reference (may remove from cached count)
    if ((atomic_fetchadd_int(&vp->v_refcnt, 1) & VREF_MASK) == 0)
        atomic_add_int(&mycpu->gd_cachedvnodes, -1);
    
    // 2. Acquire lock (shared or exclusive based on flags)
    if ((error = vn_lock(vp, flags | LK_FAILRECLAIM)) != 0) {
        vrele(vp);
        return error;
    }
    
    // 3. Check for reclaimed vnode
    if (vp->v_flag & VRECLAIMED) {
        vn_unlock(vp);
        vrele(vp);
        return ENOENT;
    }
    
    // 4. Reactivate if needed
    if (vp->v_state != VS_ACTIVE) {
        _vclrflags(vp, VINACTIVE);
        spin_lock(&vp->v_spin);
        _vactivate(vp);
        atomic_clear_int(&vp->v_refcnt, VREF_TERMINATE | VREF_FINALIZE);
        spin_unlock(&vp->v_spin);
    }
    
    return 0;
}
```

Key points:
- Can use shared locks for reactivation (important for scalability)
- Clears `VREF_TERMINATE` and `VREF_FINALIZE` on success
- Updates `v_act` activity counter for LRU decisions

### vput() - Combined Unlock and Release

```c
void vput(struct vnode *vp)
{
    vn_unlock(vp);
    vrele(vp);
}
```

## Per-CPU Vnode Lists

Vnodes are distributed across per-CPU lists to reduce contention:

```c
struct vnode_index {
    struct freelst  active_list;     /* Active vnodes */
    struct vnode    active_rover;    /* Rover for deactivation scan */
    struct freelst  inactive_list;   /* Inactive vnodes awaiting reclaim */
    struct spinlock spin;            /* Protects this CPU's lists */
    int deac_rover;                  /* Deactivation scan position */
    int free_rover;                  /* Free scan position */
} __cachealign;
```

### List Assignment

Vnodes are assigned to lists using a hash of their address:

```c
#define VLIST_HASH(vp)  (((uintptr_t)vp ^ VLIST_XOR) % \
                         VLIST_PRIME2 % (unsigned)ncpus)
```

This ensures:
- Consistent list assignment for a given vnode
- Even distribution across CPUs
- Cache-line alignment for each `vnode_index`

### Active/Inactive List Management

**`_vactivate(vp)`** - Move vnode to active list:

```c
static void _vactivate(struct vnode *vp)
{
    struct vnode_index *vi = &vnode_list_hash[VLIST_HASH(vp)];
    
    spin_lock(&vi->spin);
    
    switch(vp->v_state) {
    case VS_INACTIVE:
        TAILQ_REMOVE(&vi->inactive_list, vp, v_list);
        atomic_add_int(&mycpu->gd_inactivevnodes, -1);
        break;
    case VS_CACHED:
    case VS_DYING:
        break;
    }
    
    TAILQ_INSERT_TAIL(&vi->active_list, vp, v_list);
    vp->v_state = VS_ACTIVE;
    spin_unlock(&vi->spin);
    atomic_add_int(&mycpu->gd_activevnodes, 1);
}
```

**`_vinactive(vp)`** - Move vnode to inactive list:

```c
static void _vinactive(struct vnode *vp)
{
    struct vnode_index *vi = &vnode_list_hash[VLIST_HASH(vp)];
    
    spin_lock(&vi->spin);
    
    if (vp->v_state == VS_ACTIVE) {
        TAILQ_REMOVE(&vi->active_list, vp, v_list);
        atomic_add_int(&mycpu->gd_activevnodes, -1);
    }
    
    // Reclaimed vnodes go to head (recycled first)
    if (vp->v_flag & VRECLAIMED) {
        TAILQ_INSERT_HEAD(&vi->inactive_list, vp, v_list);
    } else {
        TAILQ_INSERT_TAIL(&vi->inactive_list, vp, v_list);
    }
    vp->v_state = VS_INACTIVE;
    spin_unlock(&vi->spin);
    atomic_add_int(&mycpu->gd_inactivevnodes, 1);
}
```

## Vnode Allocation and Recycling

### allocvnode() - Allocate a New Vnode

```c
struct vnode *allocvnode(int lktimeout, int lkflags)
{
    struct vnode *vp;
    struct vnode_index *vi = &vnode_list_hash[mycpuid];
    
    // 1. Try to reuse a reclaimed vnode from local inactive list
    spin_lock(&vi->spin);
    vp = TAILQ_FIRST(&vi->inactive_list);
    if (vp && (vp->v_flag & VRECLAIMED)) {
        // Fast path: reuse existing vnode structure
        if (vx_get_nonblock(vp) == 0) {
            // ... validation checks ...
            TAILQ_REMOVE(&vi->inactive_list, vp, v_list);
            vp->v_state = VS_DYING;
            spin_unlock(&vi->spin);
            
            bzero(vp, sizeof(*vp));  // Reuse structure
            goto initialize;
        }
    }
    spin_unlock(&vi->spin);
    
    // 2. Slow path: allocate new vnode
    vp = kmalloc_obj(sizeof(*vp), M_VNODE, M_ZERO | M_WAITOK);
    atomic_add_int(&numvnodes, 1);
    
initialize:
    // Initialize vnode fields
    lwkt_token_init(&vp->v_token, "vnode");
    lockinit(&vp->v_lock, "vnode", lktimeout, lkflags);
    spin_init(&vp->v_spin, "allocvnode");
    // ... other initialization ...
    
    vx_lock(vp);
    vp->v_refcnt = 1;
    vp->v_state = VS_CACHED;
    _vactivate(vp);
    
    return vp;
}
```

### cleanfreevnode() - Recycle Inactive Vnodes

The `cleanfreevnode()` function scans inactive lists to find vnodes suitable for recycling:

1. **Deactivation scan**: Moves vnodes from active to inactive list based on activity
2. **Reclamation scan**: Finds fully reclaimable vnodes on inactive list

```c
static struct vnode *cleanfreevnode(int maxcount)
{
    // Phase 1: Try to deactivate active vnodes
    for (count = 0; count < maxcount * 2; ++count) {
        vi = &vnode_list_hash[((unsigned)ri >> 4) % ncpus];
        vp = TAILQ_NEXT(&vi->active_rover, v_list);
        
        // Skip if referenced
        if ((vp->v_refcnt & VREF_MASK) != 0)
            continue;
            
        // Decay activity counter
        if (vp->v_act > 0) {
            vp->v_act -= VACT_INC;
            continue;
        }
        
        // Trigger deactivation via finalize
        atomic_set_int(&vp->v_refcnt, VREF_FINALIZE);
        vrele(vp);
    }
    
    // Phase 2: Find reclaimable inactive vnode
    for (count = 0; count < maxcount; ++count) {
        vp = TAILQ_FIRST(&vi->inactive_list);
        
        // Must have no refs or auxrefs
        if (vp->v_auxrefs != vp->v_namecache_count ||
            (vp->v_refcnt & ~VREF_FINALIZE) != VREF_TERMINATE + 1)
            continue;
            
        // Reclaim and return
        if ((vp->v_flag & VRECLAIMED) == 0) {
            cache_inval_vp_nonblock(vp);
            vgone_vxlocked(vp);
        }
        
        vp->v_state = VS_DYING;
        return vp;
    }
    return NULL;
}
```

### Activity Counter (v_act)

The `v_act` field implements LRU-like behavior:

```c
#define VACT_MAX    10
#define VACT_INC    2
```

- Incremented on `vget()` (up to `VACT_MAX`)
- Decremented during deactivation scans
- Vnodes with `v_act == 0` are candidates for deactivation
- VM-heavy vnodes decay slower (based on `v_object->resident_page_count`)

## Standard Vnode Lock Functions

Located in `vfs_vnops.c`, these wrap the lockmgr:

### vn_lock() - Acquire Vnode Lock

```c
int vn_lock(struct vnode *vp, int flags)
{
    int error;
    
    do {
        error = lockmgr(&vp->v_lock, flags);
        if (error == 0)
            break;
    } while (flags & LK_RETRY);
    
    // Handle reclaimed vnodes
    if (error == 0 && (vp->v_flag & VRECLAIMED)) {
        if (flags & LK_FAILRECLAIM) {
            lockmgr(&vp->v_lock, LK_RELEASE);
            error = ENOENT;
        }
    }
    return error;
}
```

Flags:
- `LK_SHARED` - Shared (read) lock
- `LK_EXCLUSIVE` - Exclusive (write) lock
- `LK_NOWAIT` - Don't block if unavailable
- `LK_RETRY` - Retry on failure
- `LK_FAILRECLAIM` - Fail if vnode is reclaimed

### vn_unlock() - Release Vnode Lock

```c
void vn_unlock(struct vnode *vp)
{
    lockmgr(&vp->v_lock, LK_RELEASE);
}
```

## Statistics and Monitoring

Global vnode statistics are tracked per-CPU and aggregated:

```c
int activevnodes;    /* sysctl debug.activevnodes */
int cachedvnodes;    /* sysctl debug.cachedvnodes */
int inactivevnodes;  /* sysctl debug.inactivevnodes */

void synchronizevnodecount(void)
{
    for (i = 0; i < ncpus; ++i) {
        globaldata_t gd = globaldata_find(i);
        nca += gd->gd_cachedvnodes;
        act += gd->gd_activevnodes;
        ina += gd->gd_inactivevnodes;
    }
    cachedvnodes = nca;
    activevnodes = act;
    inactivevnodes = ina;
}
```

## Initialization

Called from `vfsinit()`:

```c
void vfs_lock_init(void)
{
    kmalloc_obj_raise_limit(M_VNODE, 0);  /* unlimited */
    
    vnode_list_hash = kmalloc(sizeof(*vnode_list_hash) * ncpus,
                              M_VNODE_HASH, M_ZERO | M_WAITOK);
    
    for (i = 0; i < ncpus; ++i) {
        struct vnode_index *vi = &vnode_list_hash[i];
        TAILQ_INIT(&vi->inactive_list);
        TAILQ_INIT(&vi->active_list);
        TAILQ_INSERT_TAIL(&vi->active_list, &vi->active_rover, v_list);
        spin_init(&vi->spin, "vfslock");
    }
}
```

## Summary

The DragonFly vnode locking system achieves scalability through:

1. **State machine design** - Clear state transitions with well-defined locking requirements
2. **Embedded flags in refcount** - Atomic flag manipulation without separate locks
3. **Per-CPU partitioning** - Reduces cross-CPU cache line bouncing
4. **Activity-based LRU** - Intelligent recycling decisions
5. **Lockless fast paths** - Most operations use atomic CAS without locks
6. **Shared lock reactivation** - Multiple readers can reactivate simultaneously

Key invariants:
- `v_refcnt > 0` implies vnode cannot be recycled
- `v_auxrefs > 0` prevents `kfree()` of vnode structure
- `VRECLAIMED` flag prevents reactivation
- State transitions follow defined locking protocol
