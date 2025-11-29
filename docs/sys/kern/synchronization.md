# Synchronization Primitives

This document describes the synchronization primitives used throughout the DragonFly BSD kernel to coordinate access to shared resources and ensure data consistency across multiple CPUs and threads.

## Overview

DragonFly BSD provides a comprehensive hierarchy of synchronization primitives, each optimized for specific use cases. Understanding when to use each primitive is critical for writing correct and performant kernel code.

The synchronization primitives, ordered from lowest to highest level:

1. **Tokens** - DragonFly's unique per-CPU serialization mechanism (see [LWKT Threading](lwkt.md))
2. **Spinlocks** - Low-level busy-wait locks with shared/exclusive support
3. **Mutexes (mtx)** - Fast persistent locks with sleep capability and async support
4. **Lockmgr Locks** - Traditional BSD shared/exclusive locks with complex features
5. **Condition Variables** - Thread coordination using wait/signal patterns
6. **Reference Counts** - Atomic reference counting for object lifecycle management
7. **System References (sysref)** - Advanced reference counting with objcache integration

## Key Concepts

### DragonFly's Unique Approach

DragonFly BSD differs from traditional BSD and Linux kernels in its synchronization philosophy:

- **Token-based design**: Most high-level kernel operations use LWKT tokens for serialization rather than traditional locks
- **Per-CPU scheduling**: Threads are scheduled independently on each CPU, reducing global synchronization overhead
- **Reduced lock contention**: By favoring tokens and per-CPU data structures, DragonFly minimizes cache line bouncing

### Token vs. Lock Decision Tree

**Use Tokens when:**
- Protecting high-level subsystem state (VFS, VM, etc.)
- The critical section may block or call complex functions
- Lock ordering is difficult to maintain
- The code is not performance-critical

**Use Spinlocks when:**
- Critical section is very short (a few instructions)
- Cannot sleep or call blocking functions
- Need shared (reader) locks for concurrent access
- Performance is critical (e.g., per-packet network processing)

**Use Mutexes when:**
- Need to block across long-running operations
- Need asynchronous lock acquisition with callbacks
- Want recursive locking capability
- Need to hold lock across function calls that may block

**Use Lockmgr when:**
- Need complex lock operations (upgrade, downgrade, cancellation)
- Interfacing with traditional BSD code
- Need precise control over lock priority and behavior

## Synchronization Primitives

### Spinlocks

Spinlocks are the lowest-level synchronization primitive, providing both exclusive and shared locking with busy-waiting.

**Source Files:**
- `sys/kern/kern_spinlock.c` - Implementation
- `sys/sys/spinlock.h` - Data structures
- `sys/sys/spinlock2.h` - Inline functions

**Data Structure:**

```c
struct spinlock {
    int lock;        /* main spinlock */
    int update;      /* update counter */
};
```

**Lock Field Encoding:**
- Bits 0-19: Reference count
- Bit 31: `SPINLOCK_SHARED` flag
- Bits 20-30: `SPINLOCK_EXCLWAIT` counter for exclusive waiters

**Key Functions:**

- `spin_init(struct spinlock *spin, const char *desc)` - Initialize spinlock
- `spin_lock(struct spinlock *spin)` - Acquire exclusive lock (sys/kern/kern_spinlock.c:166)
- `spin_unlock(struct spinlock *spin)` - Release exclusive lock
- `spin_lock_shared(struct spinlock *spin)` - Acquire shared lock (sys/kern/kern_spinlock.c:276)
- `spin_unlock_shared(struct spinlock *spin)` - Release shared lock

**Critical Implementation Details:**

**Exclusive Lock Acquisition** (sys/kern/kern_spinlock.c:166-256):
- Increments lock with `atomic_fetchadd_int()`
- On contention, sets `SPINLOCK_EXCLWAIT` to gain priority
- Transfers high bits (EXCLWAIT counter) to low bits when acquiring
- Uses exponential backoff to reduce cache bus traffic
- Employs TSC-windowing to distribute CPU load

**Shared Lock Acquisition** (sys/kern/kern_spinlock.c:276-372):
- Sets `SPINLOCK_SHARED` flag when granted
- Gives priority to exclusive waiters (EXCLWAIT)
- Uses TSC-windowing to occasionally bypass EXCLWAIT priority to prevent starvation
- No exponential backoff (would hurt shared lock performance)

**Performance Optimizations:**
- TSC (timestamp counter) windowing distributes shared lock attempts across CPUs
- Exponential backoff prevents cache bus armageddon on multi-socket systems
- Automatic downgrade to RDTSC polling in VM guests

**When to Use:**
- Protecting per-CPU data structures accessed from multiple contexts
- Very short critical sections (microseconds)
- Cannot use tokens (e.g., in interrupt context)
- Need reader/writer concurrency

**Restrictions:**
- Cannot sleep or block
- Cannot call functions that might block
- Must not hold across function calls unless guaranteed not to block
- Keep critical sections extremely short

### Mutexes (mtx)

Mutexes provide persistent locks that can be held across blocking operations, with support for asynchronous acquisition and callbacks.

**Source Files:**
- `sys/kern/kern_mutex.c` - Implementation (sys/kern/kern_mutex.c:1-1159)
- `sys/sys/mutex.h` - Data structures
- `sys/sys/mutex2.h` - Inline functions

**Data Structures:**

```c
struct mtx {
    volatile u_int  mtx_lock;     /* lock state */
    uint32_t        mtx_flags;    /* flags */
    struct thread   *mtx_owner;   /* exclusive owner */
    mtx_link_t      *mtx_exlink;  /* exclusive wait list */
    mtx_link_t      *mtx_shlink;  /* shared wait list */
    const char      *mtx_ident;   /* identifier */
} __cachealign;

struct mtx_link {
    struct mtx_link *next;
    struct mtx_link *prev;
    struct thread   *owner;
    int             state;
    void            (*callback)(struct mtx_link *, void *arg, int error);
    void            *arg;
};
```

**Lock State Encoding:**
- Bit 31 (`MTX_EXCLUSIVE`): Exclusive lock flag
- Bit 30 (`MTX_SHWANTED`): Shared waiters present
- Bit 29 (`MTX_EXWANTED`): Exclusive waiters present
- Bit 28 (`MTX_LINKSPIN`): Link list manipulation in progress
- Bits 0-27: Reference count

**Key Functions:**

- `mtx_init(mtx_t *mtx, const char *ident)` - Initialize mutex
- `mtx_lock(mtx_t *mtx)` - Acquire exclusive lock (sys/kern/kern_mutex.c:202-224)
- `mtx_lock_sh(mtx_t *mtx)` - Acquire shared lock (sys/kern/kern_mutex.c:360-376)
- `mtx_unlock(mtx_t *mtx)` - Release lock (sys/kern/kern_mutex.c:630-735)
- `mtx_lock_ex_try(mtx_t *mtx)` - Try exclusive lock without blocking (sys/kern/kern_mutex.c:486-517)
- `mtx_downgrade(mtx_t *mtx)` - Convert exclusive to shared (sys/kern/kern_mutex.c:549-583)
- `mtx_upgrade_try(mtx_t *mtx)` - Try shared to exclusive upgrade (sys/kern/kern_mutex.c:596-623)
- `mtx_spinlock(mtx_t *mtx)` - Acquire as spinlock (sys/kern/kern_mutex.c:381-413)
- `mtx_lock_ex_link(mtx_t *mtx, mtx_link_t *link, int flags, int to)` - Async lock with callback

**Key Features:**

**Exclusive Priority** (sys/kern/kern_mutex.c:120-180):
- Exclusive requests set `MTX_EXWANTED` to prevent new shared locks
- Once EXWANTED is set, new shared requests must wait
- Prevents shared lock starvation of exclusive requests

**Asynchronous Locking** (sys/kern/kern_mutex.c:169-200):
- Caller provides `mtx_link_t` structure with callback
- If lock cannot be acquired immediately, link is queued
- Callback invoked when lock is granted
- Allows lock acquisition without blocking current thread

**Link Management** (sys/kern/kern_mutex.c:749-876):
- Exclusive and shared waiters maintained in separate circular lists
- `MTX_LINKSPIN` prevents concurrent link list manipulation
- Link lists allow precise wakeup control and priority ordering

**When to Use:**
- Protecting data structures that require blocking operations
- Need to hold lock across I/O or memory allocation
- Want asynchronous lock acquisition
- Need recursive locking capability
- Interfacing with code that may block

**Restrictions:**
- Heavier weight than spinlocks
- Not suitable for very short critical sections
- Exclusive lock holder must eventually release

### Lockmgr Locks

Lockmgr locks are traditional BSD shared/exclusive locks with extensive features including upgrades, downgrades, timeouts, and cancellation.

**Source Files:**
- `sys/kern/kern_lock.c` - Implementation (sys/kern/kern_lock.c:1-1483)
- `sys/sys/lock.h` - Data structures and API

**Data Structure:**

```c
struct lock {
    u_int           lk_flags;      /* flags */
    int             lk_timo;       /* timeout */
    uint64_t        lk_count;      /* state and counts */
    const char      *lk_wmesg;     /* wait message */
    struct thread   *lk_lockholder; /* exclusive holder */
};
```

**Count Field Encoding (64-bit):**
- Bit 30 (`LKC_EXREQ`): Exclusive request pending
- Bit 29 (`LKC_SHARED`): Shared lock(s) granted
- Bit 28 (`LKC_UPREQ`): Upgrade request pending
- Bit 27 (`LKC_EXREQ2`): Multiple exclusive waiters
- Bit 26 (`LKC_CANCEL`): Cancellation active
- Bits 0-25 (`LKC_XMASK`): Exclusive count
- Bits 32-63 (`LKC_SMASK`): Shared count (shifted by 32)

**Key Functions:**

- `lockinit(struct lock *lkp, const char *wmesg, int timo, int flags)` - Initialize lock
- `lockmgr(struct lock *lkp, u_int flags)` - Main lock operation dispatcher
- `lockmgr_shared(struct lock *lkp, u_int flags)` - Acquire shared lock (sys/kern/kern_lock.c:106-278)
- `lockmgr_exclusive(struct lock *lkp, u_int flags)` - Acquire exclusive lock (sys/kern/kern_lock.c:283-489)
- `lockmgr_upgrade(struct lock *lkp, u_int flags)` - Upgrade shared to exclusive (sys/kern/kern_lock.c:575-733)
- `lockmgr_downgrade(struct lock *lkp, u_int flags)` - Downgrade exclusive to shared (sys/kern/kern_lock.c:497-554)
- `lockmgr_release(struct lock *lkp, u_int flags)` - Release lock (sys/kern/kern_lock.c:741-966)

**Lock Operation Flags:**

- `LK_SHARED` - Acquire shared lock
- `LK_EXCLUSIVE` - Acquire exclusive lock
- `LK_UPGRADE` - Upgrade shared to exclusive (may lose lock temporarily)
- `LK_EXCLUPGRADE` - Upgrade without releasing (fails if contended)
- `LK_DOWNGRADE` - Downgrade exclusive to shared
- `LK_RELEASE` - Release lock
- `LK_NOWAIT` - Don't sleep, return EBUSY
- `LK_CANCELABLE` - Lock request can be canceled
- `LK_TIMELOCK` - Use lock's timeout value
- `LK_PCATCH` - Catch signals during sleep

**Critical Implementation Details:**

**Shared Lock Acquisition** (sys/kern/kern_lock.c:106-278):
- Blocks if `LKC_EXREQ` or `LKC_UPREQ` is set (unless `TDF_DEADLKTREAT`)
- Increments shared count (`LKC_SCOUNT`)
- Waits for `LKC_SHARED` flag to be set
- If `undo_shreq()` races to zero, may grant UPREQ or EXREQ

**Exclusive Lock Acquisition** (sys/kern/kern_lock.c:283-489):
- Sets `LKC_EXREQ` to block new shared/upgrade requests
- If can't set EXREQ (lock held exclusively), sets `LKC_EXREQ2` aggregation bit
- Waits for EXREQ to be cleared (granted)
- Granting thread sets `lk_lockholder` and count

**Upgrade Operations** (sys/kern/kern_lock.c:575-733):
- Sets `LKC_UPREQ` to request upgrade
- If only holder (`LKC_SMASK == LKC_SCOUNT`), immediately converts to exclusive
- Otherwise, waits for last shared release to grant upgrade
- `LK_EXCLUPGRADE` fails immediately if another UPREQ or EXREQ exists
- Regular `LK_UPGRADE` falls back to release+acquire if contended

**Lock Cancellation** (sys/kern/kern_lock.c:977-1022):
- Exclusive holder can call `lockmgr_cancel_beg()` to set `LKC_CANCEL`
- All pending/future `LK_CANCELABLE` requests return `ENOLCK`
- Used to abort operations on locked structures (e.g., vnode reclaim)
- Cleared automatically on final release or via `lockmgr_cancel_end()`

**Priority Handling:**
- Exclusive requests (EXREQ) have priority over new shared requests
- Upgrade requests (UPREQ) have priority over exclusive requests
- UPREQ > EXREQ > new shared locks (see `undo_shreq()` at sys/kern/kern_lock.c:1039-1091)

**When to Use:**
- VFS layer and vnode operations (traditional usage)
- Need upgrade/downgrade without releasing
- Need lock cancellation capability
- Interfacing with legacy BSD code
- Complex locking scenarios requiring fine control

**Restrictions:**
- More complex and heavier than tokens or mutexes
- Upgrade operations can fail or temporarily release lock
- Cannot use from interrupt context

### Condition Variables

Condition variables provide wait/signal coordination between threads, allowing threads to sleep until a condition becomes true.

**Source Files:**
- `sys/kern/kern_condvar.c` - Implementation (sys/kern/kern_condvar.c:1-97)
- `sys/sys/condvar.h` - API

**Data Structure:**

```c
struct cv {
    struct spinlock cv_lock;    /* protects cv_waiters */
    int             cv_waiters; /* number of waiters */
    const char      *cv_desc;   /* description */
};
```

**Key Functions:**

- `cv_init(struct cv *c, const char *desc)` - Initialize condition variable (sys/kern/kern_condvar.c:6-12)
- `cv_destroy(struct cv *c)` - Destroy condition variable
- `cv_wait(struct cv *c, struct lock *lk)` - Wait with lockmgr lock
- `cv_wait_sig(struct cv *c, struct lock *lk)` - Wait with signal catching
- `cv_timedwait(struct cv *c, struct lock *lk, int timo)` - Wait with timeout
- `cv_mtx_wait(struct cv *c, struct mtx *mtx)` - Wait with mutex
- `cv_signal(struct cv *c)` - Wake one waiter (sys/kern/kern_condvar.c:75-90)
- `cv_broadcast(struct cv *c)` - Wake all waiters
- `cv_has_waiters(const struct cv *c)` - Check if waiters present

**Implementation Details:**

The implementation is deliberately simple:

1. `cv_wait()` atomically:
   - Increments `cv_waiters` under `cv_lock` (sys/kern/kern_condvar.c:34-36)
   - Calls `tsleep_interlock()` to prepare to sleep
   - Releases the associated lock (lockmgr or mutex)
   - Sleeps on the cv address

2. `cv_signal()` atomically:
   - Decrements `cv_waiters` under `cv_lock`
   - Calls `wakeup_one()` if waiters existed (sys/kern/kern_condvar.c:86-88)

3. `cv_broadcast()` atomically:
   - Sets `cv_waiters` to zero
   - Calls `wakeup()` to wake all (sys/kern/kern_condvar.c:81-84)

**Mutex vs. Lock Versions:**
- `cv_wait(cv, lock)` uses `lksleep()` - releases lockmgr lock
- `cv_mtx_wait(cv, mtx)` uses `mtxsleep()` - releases mutex (sys/kern/kern_condvar.c:50-72)
- Both re-acquire their respective lock before returning

**When to Use:**
- Producer/consumer patterns
- Thread coordination (wait for condition to become true)
- Implementing wait queues
- Event notification between threads

**Typical Pattern:**

```c
/* Waiter thread */
mtx_lock(&resource_mtx);
while (!condition_is_true) {
    cv_wait(&resource_cv, &resource_mtx);
}
/* condition is now true and lock is held */
do_work();
mtx_unlock(&resource_mtx);

/* Signaler thread */
mtx_lock(&resource_mtx);
make_condition_true();
cv_signal(&resource_cv);  /* or cv_broadcast() */
mtx_unlock(&resource_mtx);
```

**Restrictions:**
- Must hold associated lock when calling cv_wait()
- Lock is automatically released during sleep
- Lock is automatically re-acquired before return
- Must hold lock when calling cv_signal/cv_broadcast (not strictly required but recommended)

### Reference Counting

Reference counting provides atomic lifecycle management for kernel objects.

**Source Files:**
- `sys/kern/kern_refcount.c` - Implementation (sys/kern/kern_refcount.c:1-78)
- `sys/sys/refcount.h` - Inline functions and API

**Key Functions:**

- `refcount_init(volatile u_int *countp, u_int value)` - Initialize counter
- `refcount_acquire(volatile u_int *countp)` - Add reference (sys/sys/refcount.h:48-52)
- `refcount_acquire_n(volatile u_int *countp, u_int n)` - Add n references
- `refcount_release(volatile u_int *countp)` - Drop reference, returns TRUE on last (sys/sys/refcount.h:60-64)
- `refcount_release_n(volatile u_int *countp, u_int n)` - Drop n references
- `refcount_release_wakeup(volatile u_int *countp)` - Drop with wakeup support (sys/sys/refcount.h:86-98)
- `refcount_wait(volatile u_int *countp, const char *wstr)` - Wait for count to reach zero

**Implementation Details:**

All operations use atomic instructions:

- **Acquire**: `atomic_add_acq_int(countp, 1)`
- **Release**: `atomic_fetchadd_int(countp, -1)`, returns old value
- **Release returns TRUE** if old value was 1 (last reference)

**Waiting Support** (`REFCNTF_WAITING`):

- Bit 30 of counter is `REFCNTF_WAITING` flag
- `refcount_wait()` sets this flag atomically (sys/kern/kern_refcount.c:58-77)
- `refcount_release_wakeup()` checks for flag and calls `wakeup()` on 1->0 transition (sys/sys/refcount.h:86-98)
- Allows threads to sleep waiting for count to drop to zero

**When to Use:**
- Managing object lifetimes (vnodes, vm_objects, buffers, etc.)
- Shared ownership of kernel structures
- Preventing premature deallocation
- Lockless lifecycle management

**Typical Pattern:**

```c
/* Object creation */
struct myobj *obj = kmalloc(...);
refcount_init(&obj->refcnt, 1);  /* creator holds reference */

/* Share object */
refcount_acquire(&obj->refcnt);
pass_to_another_subsystem(obj);

/* Release object */
if (refcount_release(&obj->refcnt)) {
    /* Last reference, free object */
    cleanup_obj(obj);
    kfree(obj);
}

/* Wait for all refs to drop (e.g., during unmount) */
refcount_wait(&obj->refcnt, "objwait");
/* Now safe to free even without lock */
```

**Restrictions:**
- Reference count must not overflow (wraps at 2^31-1)
- Caller must ensure object validity when acquiring reference
- Cannot use to count references if count might be zero (race)
- `refcount_wait()` should be used with `refcount_release_wakeup()`

### System Reference Counting (sysref)

System reference counting provides advanced lifecycle management integrated with the objcache allocator and cluster-wide addressing via sysids.

**Source Files:**
- `sys/kern/kern_sysref.c` - Implementation (sys/kern/kern_sysref.c:1-375)
- `sys/sys/sysref2.h` - API and inline functions

**Data Structures:**

```c
struct sysref {
    sysid_t             sysid;      /* cluster-wide unique ID */
    int                 refcnt;     /* reference count */
    u_int               flags;      /* SRF_* flags */
    struct sysref_class *srclass;   /* class descriptor */
    RB_ENTRY(sysref)    rbnode;     /* red-black tree node */
};

struct sysref_class {
    const char          *name;
    malloc_type_t       mtype;      /* malloc type */
    size_t              objsize;    /* object size */
    size_t              offset;     /* sysref offset in object */
    size_t              nom_cache;  /* nominal cache size */
    u_int               flags;
    objcache_t          *oc;        /* objcache */
    struct sysref_ops   ops;        /* callbacks */
    boolean_t           (*ctor)(void *, void *, int);
    void                (*dtor)(void *, void *);
};
```

**Lifecycle States (refcnt):**

- **-0x40000000**: Initialization in progress (not yet active)
- **Positive**: Active, each reference is +1
- **-0x40000000**: Termination in progress
- **0**: Freed (not accessible)

**Key Functions:**

- `sysref_alloc(struct sysref_class *srclass)` - Allocate object (sys/kern/kern_sysref.c:132-179)
- `sysref_init(struct sysref *sr, struct sysref_class *srclass)` - Manual init for static objects
- `sysref_activate(struct sysref *sr)` - Activate object (sys/kern/kern_sysref.c:273-286)
- `sysref_get(struct sysref *sr)` - Acquire reference (inline in sys/sysref2.h)
- `sysref_put(struct sysref *sr)` - Release reference (inline, calls `_sysref_put()` on special cases)
- `sysref_lookup(sysid_t sysid)` - Lookup by sysid

**Implementation Details:**

**Objcache Integration** (sys/kern/kern_sysref.c:193-263):

- Constructor allocates sysid and inserts into per-CPU red-black tree
- Sysid embeds CPU number in low bits for locality
- If sysid not accessed, destructor just removes from tree (fast path)
- If sysid accessed (`SRF_SYSIDUSED`), destructor fully destroys via `objcache_dtor()`

**Reference Count Lifecycle** (sys/kern/kern_sysref.c:297-360):

1. **Allocation**: refcnt = -0x40000000 (init in progress)
2. **Activation**: refcnt += 0x40000001 (becomes 1, active)
3. **Use**: refcnt incremented/decremented normally
4. **1->0 Transition**: refcnt set to -0x40000000, `terminate()` callback invoked
5. **Termination**: refcnt can still be modified during termination
6. **Final**: -0x40000000 -> 0, object returned to objcache

**Cluster Addressing:**

- Sysid uniquely identifies object across cluster
- Per-CPU red-black tree allows O(log n) lookup
- Enables cluster-wide IPC and resource sharing (future)

**When to Use:**
- Managing heavyweight kernel objects (processes, vnodes, etc.)
- Need cluster-wide addressing capability
- Want objcache integration for performance
- Object lifecycle requires termination callback

**Restrictions:**
- More complex than simple reference counting
- Requires class descriptor setup
- Termination callback must release locks
- Not suitable for lightweight objects

### Userland Mutex Support (umtx)

Userland mutex support provides system calls for efficient user-space synchronization with kernel sleep/wakeup.

**Source Files:**
- `sys/kern/kern_umtx.c` - Implementation (sys/kern/kern_umtx.c:1-307)

**Key Functions:**

- `sys_umtx_sleep(const int *ptr, int value, int timeout)` - Sleep if *ptr == value (sys/kern/kern_umtx.c:109-241)
- `sys_umtx_wakeup(const int *ptr, int count)` - Wake waiters on ptr (sys/kern/kern_umtx.c:250-306)

**Implementation Details:**

**umtx_sleep()** (sys/kern/kern_umtx.c:109-241):

1. Translates user address to physical address via `uservtophys()`
2. Optionally polls for short duration (4000ns) before sleeping
3. Re-checks value hasn't changed
4. Sleeps on physical address with `PDOMAIN_UMTX`
5. Handles discontinuities (COW, paging) with retries
6. Timeout capped at 2 seconds (caller must retry if needed)

**umtx_wakeup()** (sys/kern/kern_umtx.c:250-306):

1. Translates user address to physical address
2. Calls `wakeup_domain()` to wake waiters
3. `count == 1` wakes one, otherwise wakes all

**Performance Optimization:**

- Polls briefly with RDTSC before sleeping (avoids syscall/context switch for short locks)
- Uses physical addresses as wait channels (handles memory mapping)
- Caps timeout to avoid tracking page mapping changes

**When to Use:**
- Implementing pthread mutexes and condition variables in userspace
- Futex-like operations (Linux compatibility)
- Efficient user-space synchronization

**Restrictions:**
- User must handle spurious wakeups
- Timeout limited to 2 seconds per call
- Address must remain valid during sleep

### Sleep Queues

Sleep queues provide a FreeBSD-compatible API for thread blocking and wakeup.

**Source Files:**
- `sys/kern/subr_sleepqueue.c` - Implementation (sys/kern/subr_sleepqueue.c:1-400+)

**Data Structures:**

```c
struct sleepqueue_chain {
    struct spinlock sc_spin;
    TAILQ_HEAD(, sleepqueue_wchan) sc_wchead;
    u_int sc_free_count;
};

struct sleepqueue_wchan {
    TAILQ_ENTRY(sleepqueue_wchan) wc_entry;
    const void *wc_wchan;
    struct sleepqueue_chain *wc_sc;
    u_int wc_refs;
    int wc_type;
    u_int wc_blocked[SLEEPQ_NRQUEUES];  /* 2 queues per wchan */
};
```

**Key Functions:**

- `sleepq_lock(const void *wchan)` - Lock wait channel (sys/kern/subr_sleepqueue.c:176-216)
- `sleepq_release(const void *wchan)` - Unlock wait channel (sys/kern/subr_sleepqueue.c:221-239)
- `sleepq_add(const void *wchan, struct lock_object *lock, const char *wmesg, int flags, int queue)` - Add thread to queue (sys/kern/subr_sleepqueue.c:251-285)
- `sleepq_wait(const void *wchan, int pri)` - Sleep until woken (sys/kern/subr_sleepqueue.c:386-400)
- `sleepq_timedwait(const void *wchan, int pri)` - Sleep with timeout
- `sleepq_signal(const void *wchan, int flags, int pri, int queue)` - Wake one thread
- `sleepq_broadcast(const void *wchan, int flags, int pri, int queue)` - Wake all threads

**Implementation Details:**

- Global hash table of wait channels (1024 buckets)
- Each wait channel has 2 sub-queues (typically for different priorities)
- Uses DragonFly's `tsleep()`/`wakeup()` under the hood
- Maintains blocked counts for each queue
- Reference counted wait channel structures

**When to Use:**
- FreeBSD compatibility (e.g., Linux KPI emulation)
- Prefer native `tsleep()`/`wakeup()` for new DragonFly code
- Multiple priority levels needed per wait channel

## Synchronization Primitive Comparison

| Primitive | Can Sleep | Shared Locks | Recursive | Async | Priority | Use Case |
|-----------|-----------|--------------|-----------|-------|----------|----------|
| **Token** | Yes | No | Yes | No | N/A | High-level subsystems (VFS, VM) |
| **Spinlock** | No | Yes | No | No | Excl > Shared | Short critical sections, per-CPU data |
| **Mutex** | Yes | Yes | Yes | Yes | Excl > Shared | Moderate critical sections, async I/O |
| **Lockmgr** | Yes | Yes | Yes | No | Upgrade > Excl > Shared | VFS vnodes, complex lock operations |
| **Condvar** | Yes | N/A | N/A | No | N/A | Thread coordination, wait/signal |
| **Refcount** | N/A | N/A | N/A | No | N/A | Object lifecycle management |
| **Sysref** | N/A | N/A | N/A | No | N/A | Complex object lifecycle, objcache |
| **Umtx** | Yes | N/A | N/A | No | N/A | Userland synchronization |

### Performance Characteristics

**Tokens:**
- Overhead: Low for uncontended, moderate for contested
- Cache impact: Low (per-CPU, no atomic ops when acquired)
- Best for: High-level, infrequent operations

**Spinlocks:**
- Overhead: Very low
- Cache impact: High under contention (busy-waiting)
- Best for: Very short critical sections, interrupt context

**Mutexes:**
- Overhead: Low-to-moderate
- Cache impact: Moderate (atomic ops, link management)
- Best for: Medium critical sections with potential blocking

**Lockmgr:**
- Overhead: Moderate-to-high
- Cache impact: Moderate
- Best for: Complex locking scenarios, VFS operations

## Code Examples

### Example 1: Spinlock Protecting Per-Packet Metadata

```c
struct packet_queue {
    struct spinlock     pq_spin;
    TAILQ_HEAD(, packet) pq_list;
    int                 pq_count;
};

void
enqueue_packet(struct packet_queue *pq, struct packet *pkt)
{
    spin_lock(&pq->pq_spin);
    TAILQ_INSERT_TAIL(&pq->pq_list, pkt, pkt_entry);
    pq->pq_count++;
    spin_unlock(&pq->pq_spin);
}

struct packet *
dequeue_packet(struct packet_queue *pq)
{
    struct packet *pkt;
    
    spin_lock(&pq->pq_spin);
    pkt = TAILQ_FIRST(&pq->pq_list);
    if (pkt != NULL) {
        TAILQ_REMOVE(&pq->pq_list, pkt, pkt_entry);
        pq->pq_count--;
    }
    spin_unlock(&pq->pq_spin);
    
    return pkt;
}
```

### Example 2: Mutex with Blocking Operation

```c
struct device_state {
    struct mtx          ds_mtx;
    int                 ds_flags;
    struct bio_queue    ds_bioq;
};

void
device_submit_bio(struct device_state *ds, struct bio *bio)
{
    mtx_lock(&ds->ds_mtx);
    
    if (ds->ds_flags & DSF_SUSPENDED) {
        /* May need to block waiting for resume */
        while (ds->ds_flags & DSF_SUSPENDED) {
            cv_mtx_wait(&ds->ds_resume_cv, &ds->ds_mtx);
        }
    }
    
    /* Enqueue bio */
    TAILQ_INSERT_TAIL(&ds->ds_bioq, bio, bio_link);
    
    /* Kick device (may issue I/O, which blocks) */
    device_start_io(ds);
    
    mtx_unlock(&ds->ds_mtx);
}
```

### Example 3: Condition Variable Wait/Signal

```c
struct work_queue {
    struct mtx              wq_mtx;
    struct cv               wq_cv;
    TAILQ_HEAD(, work_item) wq_items;
    int                     wq_shutdown;
};

/* Worker thread */
void
worker_thread(struct work_queue *wq)
{
    struct work_item *item;
    
    mtx_lock(&wq->wq_mtx);
    
    while (!wq->wq_shutdown) {
        item = TAILQ_FIRST(&wq->wq_items);
        if (item == NULL) {
            /* No work, sleep until signaled */
            cv_mtx_wait(&wq->wq_cv, &wq->wq_mtx);
            continue;
        }
        
        TAILQ_REMOVE(&wq->wq_items, item, wi_entry);
        mtx_unlock(&wq->wq_mtx);
        
        /* Process item without holding lock */
        process_work_item(item);
        
        mtx_lock(&wq->wq_mtx);
    }
    
    mtx_unlock(&wq->wq_mtx);
}

/* Submitter */
void
submit_work(struct work_queue *wq, struct work_item *item)
{
    mtx_lock(&wq->wq_mtx);
    TAILQ_INSERT_TAIL(&wq->wq_items, item, wi_entry);
    cv_signal(&wq->wq_cv);  /* Wake one worker */
    mtx_unlock(&wq->wq_mtx);
}
```

### Example 4: Reference Counting for Object Lifecycle

```c
struct cached_object {
    refcount_t          co_refs;
    struct spinlock     co_spin;
    void                *co_data;
    /* ... */
};

struct cached_object *
cache_lookup(struct cache *cache, uint64_t key)
{
    struct cached_object *co;
    
    spin_lock(&cache->cache_spin);
    co = cache_find(cache, key);
    if (co != NULL) {
        refcount_acquire(&co->co_refs);
    }
    spin_unlock(&cache->cache_spin);
    
    return co;  /* caller now owns reference */
}

void
cache_release(struct cached_object *co)
{
    if (refcount_release(&co->co_refs)) {
        /* Last reference, free object */
        kfree(co->co_data, M_CACHE);
        kfree(co, M_CACHE);
    }
}
```

### Example 5: Lockmgr Upgrade Operation

```c
int
vnode_truncate(struct vnode *vp, off_t new_size)
{
    int error;
    
    /* Start with shared lock for size check */
    lockmgr(&vp->v_lock, LK_SHARED);
    
    if (vp->v_size <= new_size) {
        /* Nothing to do */
        lockmgr(&vp->v_lock, LK_RELEASE);
        return 0;
    }
    
    /* Need exclusive lock to modify */
    error = lockmgr(&vp->v_lock, LK_UPGRADE);
    if (error) {
        /* Lock was released, re-acquire exclusive */
        return error;
    }
    
    /* Now have exclusive lock */
    vnode_truncate_locked(vp, new_size);
    
    lockmgr(&vp->v_lock, LK_RELEASE);
    return 0;
}
```

## Subsystem Interactions

### Relationship to LWKT

All synchronization primitives integrate with LWKT threading:

- **Critical sections**: Spinlocks and tokens use `crit_enter()`/`crit_exit()` to prevent preemption
- **Thread scheduling**: Blocking locks deschedule via `lwkt_deschedule()`
- **Per-CPU data**: Spinlocks often protect per-CPU structures accessed via `mycpu`
- **Token precedence**: Tokens are typically acquired before lower-level locks

### Relationship to Sleep/Wakeup

- **tsleep()**: Used by mutexes, lockmgr, and condition variables
- **tsleep_interlock()**: Prepares atomic sleep without races
- **wakeup()**: Used by cv_signal(), cv_broadcast(), and lock releases
- **Sleep domains**: PDOMAIN_UMTX, PDOMAIN_FBSD0, etc. for isolation

### Relationship to VM

- **Page faults**: Can occur while holding tokens or sleeping locks, but not spinlocks
- **Memory allocation**: `kmalloc()` may block, cannot call while holding spinlock
- **Objcache**: Sysref integrates with objcache for efficient allocation
- **COW handling**: Umtx uses physical addresses to handle COW transparently

## Best Practices

### General Guidelines

1. **Prefer tokens for high-level code**: Unless performance is critical or in interrupt context
2. **Keep spinlock critical sections tiny**: Measure in instructions, not lines of code
3. **Don't hold spinlocks across function calls**: Unless function is guaranteed not to block
4. **Use shared locks when possible**: Reduces contention for read-heavy workloads
5. **Avoid lock nesting**: If unavoidable, maintain consistent lock order
6. **Use condition variables for coordination**: Better than polling in a loop

### Common Pitfalls

1. **Holding spinlock across blocking function**: Causes panic or deadlock
2. **Sleeping with token but not expecting it**: Other code may assume token held continuously
3. **Reference count overflow**: Not checking for wraparound
4. **Lock order violation**: Acquiring locks in inconsistent order causes deadlock
5. **Missing wakeup**: Forgetting cv_signal() causes permanent sleep
6. **Umtx address changes**: COW or munmap while threads sleeping

### Debugging Tips

1. **INVARIANTS kernel**: Enables lock assertion checking
2. **witness**: Tracks lock ordering violations (when enabled)
3. **KTR tracing**: Can trace spinlock contention
4. **indefinite_info**: Automatic warnings for locks held too long
5. **lock_test_mode**: Special debugging mode for lockmgr

## See Also

- [LWKT Threading](lwkt.md) - Thread management and tokens
- [Processes](processes.md) - Process management
- [Scheduling](scheduling.md) - Thread scheduling
- [Memory Management](memory.md) - VM interactions

## References

- `sys/kern/kern_spinlock.c` - Spinlock implementation
- `sys/kern/kern_lock.c` - Lockmgr implementation  
- `sys/kern/kern_mutex.c` - Mutex implementation
- `sys/kern/kern_condvar.c` - Condition variable implementation
- `sys/kern/kern_refcount.c` - Reference counting
- `sys/kern/kern_sysref.c` - System reference counting
- `sys/kern/kern_umtx.c` - Userland mutex support
- `sys/kern/subr_sleepqueue.c` - Sleep queue implementation
