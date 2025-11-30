# CPU Scheduling

## Overview

DragonFly's CPU scheduling system consists of two distinct layers:

1. **LWKT (Light Weight Kernel Threads) Layer** - Low-level thread scheduling that handles all kernel threads and provides the foundation for userland scheduling
2. **User Scheduler Layer** - Pluggable schedulers that implement policies for userland process scheduling

This document focuses on the user scheduler layer and the sleep/wakeup synchronization primitives that coordinate thread blocking and resumption.

**Key source files:**
- `kern_sched.c` - POSIX real-time scheduling support (ksched)
- `kern_synch.c` - Sleep/wakeup, tsleep/wakeup infrastructure
- `kern_usched.c` - User scheduler registration and management
- `usched_bsd4.c` - BSD4 scheduler (original DragonFly)
- `usched_dfly.c` - DFLY scheduler (message-based, default)
- `usched_dummy.c` - Dummy scheduler (for testing/reference)

---

## Architecture

### Two-Layer Design

```
┌─────────────────────────────────────────┐
│     Userland Processes (LWPs)           │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│   User Scheduler Layer (pluggable)      │
│   - usched_bsd4 / usched_dfly            │
│   - Run queues per scheduler             │
│   - CPU affinity management              │
│   - Priority calculations                │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│   LWKT Scheduler (per-CPU)               │
│   - All kernel threads                   │
│   - Thread preemption                    │
│   - Context switching                    │
└──────────────────────────────────────────┘
```

### Pluggable User Schedulers

DragonFly allows multiple user schedulers to coexist. Each process is assigned a scheduler (`p->p_usched`), and the system provides a common interface (`struct usched`) that all schedulers must implement.

---

## Sleep/Wakeup Infrastructure

### Overview (kern_synch.c)

The sleep/wakeup mechanism is DragonFly's primary thread synchronization primitive, allowing threads to block waiting for events and be awakened when those events occur.

**Core functions:**
- `tsleep()` - Sleep on an identifier (ident) with timeout and signal handling
- `wakeup()` - Wake all threads sleeping on an identifier
- `wakeup_one()` - Wake one thread sleeping on an identifier
- `tsleep_interlock()` - Prepare to sleep without blocking yet
- `ssleep()`, `lksleep()`, `mtxsleep()`, `zsleep()` - Variants that atomically release locks

### Sleep Queue Hash Table

**Data structure: `struct tslpque`** (kern_synch.c:68)

```c
struct tslpque {
    TAILQ_HEAD(, thread)  queue;
    const volatile void   *ident0;
    const volatile void   *ident1;
    const volatile void   *ident2;
    const volatile void   *ident3;
};
```

Each CPU maintains its own hash table of sleep queues (`gd->gd_tsleep_hash`). The hash is computed from the sleep identifier (typically an address):

```c
#define LOOKUP(x)  ((((uintptr_t)(x) + ((uintptr_t)(x) >> 18)) ^ \
                     LOOKUP_PRIME) % slpque_tablesize)
#define TCHASHSHIFT(x)  ((x) >> 4)
```

The global `slpque_cpumasks[]` array tracks which CPUs have threads sleeping on each hash bucket, enabling efficient cross-CPU wakeups.

### tsleep() Flow

**Function: `tsleep()`** (kern_synch.c:512)

```
1. Check for delayed wakeups (TDF_DELAYED_WAKEUP)
2. Handle early boot / panic case (just yield briefly)
3. Enter critical section
4. Interlock with sleep queue (if not already done via PINTERLOCKED)
5. Handle process state (SCORE for coredump)
6. Check for pending signals (if PCATCH set)
   - Early return with EINTR/ERESTART if signal pending
7. Set LWP_SINTR flag (if PCATCH) to allow signal wakeup
8. Release from user scheduler (p_usched->release_curproc)
9. Verify still on sleep queue (race detection)
10. Deschedule from LWKT (lwkt_deschedule_self)
11. Set TDF_TSLEEP_DESCHEDULED flag
12. Setup timeout callout (if timo != 0)
13. Set lp->lwp_stat = LSSLEEP
14. lwkt_switch() - actually sleep
15. [WOKEN UP]
16. Cancel timeout (if set)
17. Remove from sleep queue
18. Check for signals again (if PCATCH)
19. Clear LWP_SINTR flag
20. Set lp->lwp_stat = LSRUN
21. Exit critical section
22. Return error code (0, EWOULDBLOCK, EINTR, ERESTART)
```

**Key points:**
- The entire sleep setup runs in a critical section to prevent migration
- `tsleep_interlock()` can be called beforehand to set up the sleep queue while still holding locks
- Timeouts are handled by `endtsleep()` callback
- Signal delivery can interrupt sleep (if PCATCH set)

### tsleep_interlock() Pattern

**Function: `tsleep_interlock()`** (kern_synch.c:451)

This function enables a common synchronization pattern:

```c
// Critical pattern:
mutex_lock(&lock);
// Check condition
if (!condition_met) {
    tsleep_interlock(&condition_ident, 0);  // Setup sleep
    mutex_unlock(&lock);                     // Release lock
    tsleep(&condition_ident, PINTERLOCKED, "wait", 0);
    mutex_lock(&lock);
}
mutex_unlock(&lock);
```

The `PINTERLOCKED` flag tells `tsleep()` that the sleep queue interlocking has already been done, preventing races between the lock release and the sleep.

### Wakeup Mechanism

**Function: `_wakeup()`** (kern_synch.c:999)

Wakeup searches the sleep queue hash bucket for matching threads:

```
1. Enter critical section
2. Compute hash bucket from ident
3. Scan local CPU's sleep queue for matching threads
   - Match on: td->td_wchan == ident && td->td_wdomain == domain
4. For each match:
   - Remove from sleep queue (_tsleep_remove)
   - Set td->td_wakefromcpu (for scheduler affinity)
   - Schedule thread (lwkt_schedule) if TDF_TSLEEP_DESCHEDULED
   - If PWAKEUP_ONE flag, stop after first wakeup
5. Clean up queue tracking (ident0-3, cpumask bit)
6. Send IPIs to other CPUs with matching threads
   - Check slpque_cpumasks[cid] for remote CPUs
   - Send _wakeup IPI with ident and domain
7. Exit critical section
```

**Wakeup variants:**
- `wakeup(ident)` - Wake all threads on all CPUs
- `wakeup_one(ident)` - Wake one thread on any CPU
- `wakeup_mycpu(ident)` - Wake threads on current CPU only
- `wakeup_domain(ident, domain)` - Wake threads in specific domain

### Delayed Wakeup Optimization

**Functions: `wakeup_start_delayed()`, `wakeup_end_delayed()`** (kern_synch.c:1266, 1276)

For code that performs many wakeups in quick succession, delayed wakeups batch them:

```c
wakeup_start_delayed();
// Multiple wakeups are queued in gd->gd_delayed_wakeup[0..1]
wakeup(ident1);
wakeup(ident2);
// ...
wakeup_end_delayed();  // Actually issue the wakeups
```

This reduces IPI traffic when many wakeups occur close together.

### Sleep Queue Domains (PDOMAIN_*)

Sleep identifiers can be partitioned into domains to prevent false wakeups:

- `PDOMAIN_UMTX` - User mutex domain
- Default domain (0) - General purpose

Threads sleep and wake within their domain, preventing cross-contamination.

---

## POSIX Real-Time Scheduling (kern_sched.c)

### Overview

The `ksched` module provides POSIX.1b real-time scheduling extensions:
- `SCHED_FIFO` - First-in-first-out realtime
- `SCHED_RR` - Round-robin realtime  
- `SCHED_OTHER` - Standard timesharing

**Key functions:**
- `ksched_setscheduler()` - Set scheduling policy and priority
- `ksched_getscheduler()` - Get current scheduling policy
- `ksched_setparam()` / `ksched_getparam()` - Get/set sched parameters
- `ksched_yield()` - Voluntarily yield CPU
- `ksched_get_priority_max()` / `_min()` - Query priority ranges
- `ksched_rr_get_interval()` - Get round-robin interval

### Priority Mapping

POSIX requires higher numbers = higher priority, but DragonFly's internal rtprio uses lower numbers = higher priority. The ksched module performs the inversion:

```c
#define p4prio_to_rtpprio(P)  (RTP_PRIO_MAX - (P))
#define rtpprio_to_p4prio(P)  (RTP_PRIO_MAX - (P))

#define P1B_PRIO_MIN  rtpprio_to_p4prio(RTP_PRIO_MAX)
#define P1B_PRIO_MAX  rtpprio_to_p4prio(RTP_PRIO_MIN)
```

### Real-Time Priority Types

Stored in `lp->lwp_rtprio`:

- `RTP_PRIO_FIFO` - SCHED_FIFO: runs until blocked or preempted by higher priority
- `RTP_PRIO_REALTIME` - SCHED_RR: round-robin with other same-priority RT threads
- `RTP_PRIO_NORMAL` - SCHED_OTHER: standard timesharing
- `RTP_PRIO_IDLE` - Idle priority

Real-time threads (`RTP_PRIO_FIFO` and `RTP_PRIO_REALTIME`) always run before normal priority threads.

---

## User Scheduler Management (kern_usched.c)

### Scheduler Registration

**Function: `usched_ctl()`** (kern_usched.c:96)

Schedulers register/unregister with the system:

```c
struct usched {
    TAILQ_ENTRY(usched) entry;
    const char *name;
    const char *desc;
    void (*usched_register)(void);
    void (*usched_unregister)(void);
    void (*acquire_curproc)(struct lwp *);
    void (*release_curproc)(struct lwp *);
    void (*setrunqueue)(struct lwp *);
    void (*schedulerclock)(struct lwp *, sysclock_t, sysclock_t);
    void (*recalculate)(struct lwp *);
    void (*resetpriority)(struct lwp *);
    void (*forking)(struct lwp *parent, struct lwp *child);
    void (*exiting)(struct lwp *, struct proc *);
    void (*uload_update)(struct lwp *);
    void (*setcpumask)(struct lwp *, cpumask_t);
    void (*yield)(struct lwp *);
    void (*changedcpu)(struct lwp *);
};
```

Built-in schedulers:
- `usched_bsd4` - Original DragonFly scheduler
- `usched_dfly` - New message-based scheduler (default)
- `usched_dummy` - Minimal reference implementation

### Scheduler Selection

**Function: `usched_init()`** (kern_usched.c:59)

At boot, the system selects the default scheduler based on `kern.user_scheduler` environment variable:
- `"dfly"` → usched_dfly (default)
- `"bsd4"` → usched_bsd4
- `"dummy"` → usched_dummy

Each process inherits its scheduler from its parent on fork. The scheduler can be changed via `usched_set(2)` syscall.

### CPU Affinity Management

**Functions: `sys_lwp_setaffinity()`, `sys_lwp_getaffinity()`** (kern_usched.c:411, 363)

DragonFly allows per-LWP CPU affinity masks (`lp->lwp_cpumask`):

```c
// Set affinity
cpumask_t mask;
CPUMASK_ASSBIT(mask, target_cpu);
lwp_setaffinity(pid, tid, &mask);

// Get affinity  
lwp_getaffinity(pid, tid, &mask);
```

When an LWP's affinity is changed:
1. Update `lp->lwp_cpumask`
2. If current CPU not in new mask, call `lwkt_migratecpu()` to move thread
3. Call `p_usched->changedcpu(lp)` to notify scheduler

### usched_set() Syscall

**Function: `sys_usched_set()`** (kern_usched.c:184)

Commands:
- `USCHED_SET_SCHEDULER` - Change process's scheduler
- `USCHED_SET_CPU` - Pin LWP to specific CPU
- `USCHED_GET_CPU` - Get current CPU
- `USCHED_ADD_CPU` - Add CPU to affinity mask
- `USCHED_DEL_CPU` - Remove CPU from affinity mask
- `USCHED_SET_CPUMASK` - Set full affinity mask
- `USCHED_GET_CPUMASK` - Get affinity mask

### Scheduler Clock

**Function: `usched_schedulerclock()`** (kern_usched.c:152)

Called from the system's scheduler clock (hardclock) on each CPU at `ESTCPUFREQ` (typically 10 Hz). Each registered scheduler's `schedulerclock()` method is invoked to:
- Update per-thread statistics (estcpu, pctcpu)
- Detect if round-robin interval expired
- Request reschedules as needed

---

## BSD4 Scheduler (usched_bsd4.c)

### Overview

The BSD4 scheduler is a traditional BSD-style scheduler with:
- 32 run queues per priority class (realtime, normal, idle)
- Priority calculated from nice value and CPU usage (estcpu)
- Round-robin within each queue
- Simple CPU load balancing

**Priority classes:**
- Realtime: 0-127 (maps to 32 queues via priorities/4)
- Normal: 128-255
- Idle: 256-383
- Thread: 384-511 (kernel threads)

### Data Structures

**Per-CPU state: `struct usched_bsd4_pcpu`** (usched_bsd4.c:131)

```c
struct usched_bsd4_pcpu {
    struct thread  *helper_thread;
    short          rrcount;        // Round-robin counter
    short          upri;           // User priority of current process
    struct lwp     *uschedcp;      // Current scheduled LWP
    struct lwp     *old_uschedcp;  // Previous LWP
    cpu_node_t     *cpunode;       // CPU topology node
};
```

**Global run queues:**
- `bsd4_queues[32]` - Normal priority queues
- `bsd4_rtqueues[32]` - Realtime priority queues
- `bsd4_idqueues[32]` - Idle priority queues
- `bsd4_queuebits`, `bsd4_rtqueuebits`, `bsd4_idqueuebits` - Bitmasks indicating non-empty queues

### Priority Calculation

**Function: `bsd4_resetpriority()`**

The normal priority calculation considers:
1. Base priority from nice value (`lp->lwp_rtprio.prio`)
2. CPU usage (estcpu): `lp->lwp_estcpu`
3. Penalty for batch processes

```c
// Simplified priority formula
pri = PRIBASE_NORMAL + (nice * NICEPPQ) + (estcpu / ESTCPUPPQ)
lwp_priority = min(pri, MAXPRI-1)
```

**estcpu** (estimated CPU usage) is a decay-average:
- Incremented on each scheduler clock tick when running
- Decayed by factor over time
- Used to penalize CPU-bound processes relative to I/O-bound

### Run Queue Management

**Function: `bsd4_setrunqueue_locked()`**

When placing an LWP on the run queue:

```
1. Determine queue index from priority
   - Realtime/Idle: direct mapping
   - Normal: (priority - PRIBASE_NORMAL) / PPQ
2. Add to tail of appropriate queue (FIFO within priority)
3. Set corresponding bit in queuebits
4. Increment bsd4_runqcount
5. Set LWP_MP_ONRUNQ flag
```

**Function: `bsd4_chooseproc_locked()`**

Selecting next LWP to run:

```
1. Check realtime queues first (highest priority)
   - Find first set bit in bsd4_rtqueuebits
   - Take head of that queue
2. If no realtime, check normal queues
   - Find first set bit in bsd4_queuebits  
   - Take head of that queue
3. If no normal, check idle queues
   - Find first set bit in bsd4_idqueuebits
   - Take head of that queue
4. Return selected LWP (or NULL if all empty)
```

### CPU Selection Heuristics

**Function: `bsd4_setrunqueue()`**

When scheduling an LWP, BSD4 tries to place it intelligently:

1. **Check for free CPUs** (not running user processes)
   - Prefer CPUs in same CPU package (cache coherency)
   - Use topology information (`cpunode`)

2. **Check running CPUs**
   - Find CPU running lower-priority LWP
   - Use upri (user priority) comparison

3. **Round-robin if all busy**
   - Use `bsd4_scancpu` to distribute load

4. **Send wakeup IPI** to selected CPU if necessary

### Acquire/Release Curproc

**Function: `bsd4_acquire_curproc()`** (usched_bsd4.c:330)

When returning to userland:

```
1. Remove from tsleep queue if necessary
2. Recalculate estcpu
3. Handle user_resched request (release and reselect)
4. Loop until we become dd->uschedcp:
   - Try to steal current designation
   - Or place on runqueue and switch away
5. Mark CPU as running user process
```

**Function: `bsd4_release_curproc()`**

When entering kernel:

```
1. Clear dd->uschedcp
2. Call bsd4_select_curproc() to pick new LWP
3. Mark CPU as not running user process if no LWP selected
```

### Scheduler Clock

**Function: `bsd4_schedulerclock()`**

Called at ESTCPUFREQ for running LWP:

```
1. Increment estcpu (CPU usage accounting)
2. Increment rrcount (round-robin counter)
3. If rrcount >= rrinterval:
   - Reset rrcount
   - Request user reschedule (need_user_resched)
   - Triggers round-robin rotation
```

---

## DFLY Scheduler (usched_dfly.c)

### Overview

The DFLY scheduler is DragonFly's modern, message-based scheduler featuring:
- Per-CPU run queues (no global lock on fast path)
- Sophisticated load balancing with topology awareness
- IPC (Inter-Process Communication) affinity detection
- NUMA awareness
- Proactive load rebalancing

**Key advantages:**
- Better scalability on many-CPU systems
- Reduced lock contention (per-CPU spinlocks)
- Smarter CPU selection for IPC-heavy workloads
- Topology-aware scheduling (cores, packages, NUMA nodes)

### Data Structures

**Per-CPU state: `struct usched_dfly_pcpu`** (sys/usched_dfly.h)

```c
struct usched_dfly_pcpu {
    struct spinlock spin;             // Per-CPU lock
    struct thread   *helper_thread;   // Rebalancing helper
    u_short         scancpu;          // Next CPU to scan
    u_short         cpuid;
    u_short         upri;             // Highest user priority
    u_short         ucount;           // User thread count
    u_short         uload;            // Load metric
    int             rrcount;          // Round-robin counter
    struct lwp      *uschedcp;        // Current user LWP
    struct lwp      *old_uschedcp;    
    cpu_node_t      *cpunode;         // Topology node
    
    // Run queues (32 per priority class)
    struct lwp_queue queues[NQS];
    struct lwp_queue rtqueues[NQS];
    struct lwp_queue idqueues[NQS];
    u_int32_t       queuebits;
    u_int32_t       rtqueuebits;
    u_int32_t       idqueuebits;
    u_int32_t       runqcount;
    
    // IPC affinity tracking
    cpumask_t       ipimask;          // CPUs to send IPI
};
```

### Priority Calculation

Similar to BSD4, but with additional fairness tuning:

```c
pri = PRIBASE_NORMAL + 
      (nice * NICEPPQ) + 
      (estcpu / ESTCPUPPQ) +
      batch_penalty
```

The DFLY scheduler uses more sophisticated estcpu decay and better handles bursty workloads.

### CPU Selection Algorithm

**Function: `dfly_choose_best_queue()`**

The heart of DFLY scheduling. Uses a weighted scoring system:

```
For each potential target CPU:
    score = 0
    
    // Weight1: Prefer keeping thread on current CPU
    if (cpu == lp->lwp_thread->td_gd->gd_cpuid)
        score -= weight1
    
    // Weight2: IPC affinity (wakefromcpu)
    // Prefer scheduling near the CPU that last woke us
    if (topology_allows_ipc_optimization(cpu, wakefromcpu))
        score -= weight2
    
    // Weight3: Queue length penalty
    score += dd->runqcount * weight3
    
    // Weight4: Availability (other CPU has lower priority thread)
    if (dd->upri > our_priority)
        score -= weight4
    
    // Weight5: NUMA node memory weighting
    score += numa_memory_weight(cpu) * weight5
    
    // Weight6/7: Transfer hysteresis for stability
    
Select CPU with lowest (best) score
```

**Default weights** (usched_dfly.c:280-286):
- `weight1 = 30` - Affinity to current CPU
- `weight2 = 180` - IPC locality (strongest)
- `weight3 = 10` - Queue length
- `weight4 = 120` - CPU availability
- `weight5 = 50` - NUMA preference
- `weight6 = 0` - Rebalance hysteresis
- `weight7 = -100` - Idle pull hysteresis

### IPC Affinity Detection

**Key insight:** When thread A wakes thread B, they likely have a producer-consumer relationship. Scheduling B near A reduces cache misses and IPC latency.

Tracked via:
- `td->td_wakefromcpu` - CPU that last woke this thread (set in wakeup)
- weight2 heuristic advantages scheduling on nearby CPUs

The topology-aware logic considers:
- Same logical CPU (hyperthreading sibling) - very strong affinity
- Same physical package - strong affinity  
- Same NUMA node - moderate affinity
- Different NUMA nodes - no affinity

### Load Rebalancing

**Function: `dfly_choose_worst_queue()`**

The helper thread (`dfly_pcpu[cpu].helper_thread`) periodically rebalances:

```
1. Identify overloaded CPU (worst_queue)
   - High runqcount relative to others
   
2. Identify underloaded CPU (best_queue)
   - Low/zero runqcount
   
3. Transfer LWP from worst to best
   - Call dfly_changeqcpu_locked()
   - Move LWP between per-CPU queues
   
4. Send IPI to target CPU to schedule the LWP
```

**Rebalancing features** (controlled by `usched_dfly_features`):
- `0x01` - Idle CPU pulling (default on)
- `0x02` - Proactive pushing (default on)
- `0x04` - Rebalancing rover (default on)
- `0x08` - More aggressive pushing (default on)

### Acquire/Release Curproc

**Function: `dfly_acquire_curproc()`** (usched_dfly.c:325)

```
1. Quick path: if already uschedcp and no resched needed, return
2. Remove from tsleep queue if needed
3. Recalculate estcpu
4. Handle user_resched: release and reselect
5. Loop until dd->uschedcp == lp:
   - Check if outcast (CPU affinity violation)
     - If so, migrate to best CPU via dfly_changeqcpu_locked()
   - Try to become uschedcp
   - Or place on runqueue and switch away
```

**Function: `dfly_release_curproc()`**

```
1. Acquire per-CPU spinlock
2. If we are dd->uschedcp:
   - Call dfly_select_curproc() to pick new LWP
   - Consider local runqueue first
   - May pull from other CPUs if idle
3. Release spinlock
```

### Per-CPU Run Queues

Unlike BSD4's global queues, DFLY maintains separate 32-queue arrays on each CPU. This eliminates global lock contention but requires inter-CPU coordination for load balancing.

**Trade-off:**
- **Pro:** Much better scalability, less contention
- **Con:** Requires active rebalancing to prevent imbalance

The helper threads and IPC affinity heuristics work together to keep the system balanced without needing a global view.

### Fork Behavior

**Function: `dfly_forking()`**

When a process forks:
- Feature `0x20` (default): Choose best CPU for child based on IPC affinity
- Feature `0x40`: Keep child on current CPU
- Feature `0x80`: Random CPU assignment

The default (`0x20`) recognizes that fork is often followed by exec (in child) or wait (in parent), creating an IPC relationship. The scheduler tries to place the child near the parent for efficient cache sharing.

---

## Dummy Scheduler (usched_dummy.c)

### Purpose

The dummy scheduler is a minimal reference implementation demonstrating the scheduler API. It's not suitable for production but useful for:
- Understanding the scheduler interface
- Testing scheduler infrastructure
- Prototyping new scheduler ideas

### Design

- Single global run queue (`dummy_runq`)
- Global spinlock (`dummy_spin`)
- No sophisticated CPU selection
- No priority calculations
- Simple FIFO scheduling

**Key characteristics:**
- Acquires first available CPU
- Helper thread per CPU to accept work
- Round-robin at fixed interval
- No load balancing heuristics

This simplicity makes it easy to understand the flow of `acquire_curproc`, `release_curproc`, `setrunqueue`, etc., without the complexity of real scheduling policies.

---

## Scheduler Clock and Statistics

### schedcpu() Callout

**Function: `schedcpu()`** (kern_synch.c:203)

Called once per second on each CPU to update statistics:

```
1. Scan all processes (allproc_scan):
   - Increment p_swtime (swap time)
   - For each LWP:
     - Increment lwp_slptime if sleeping
     - Recalculate estcpu (if active or slptime < 2)
     - Decay pctcpu (percentage CPU)
     - Call p_usched->recalculate(lp)
   
2. Check CPU resource limits (schedcpu_resource):
   - Sum td_sticks + td_uticks for all threads
   - Call plimit_testcpulimit()
   - Send SIGXCPU or kill if limit exceeded
   
3. Wakeup &lbolt and lbolt_syncer (on CPU 0)
4. Reschedule callout for next second
```

### Load Average Calculation

**Function: `loadav()`** (kern_synch.c:1405)

Called every 5 seconds (with randomization) to compute load averages:

```
1. Scan all LWPs (alllwp_scan)
   - Count runnable LWPs (LSRUN state, not blocked)
   - Store count in gd->gd_loadav_nrunnable
   
2. On CPU 0:
   - Sum counts from all CPUs
   - Update averunnable.ldavg[0..2] (1, 5, 15 minute averages)
   - Use exponential decay with FSCALE fixed-point math
```

The load average represents the average number of runnable threads over different time periods, a key system health metric.

### CPU Usage Tracking (estcpu, pctcpu)

**estcpu** - Estimated CPU usage:
- Incremented each scheduler clock tick when LWP is running
- Decayed over time (typically 8/10 per second)
- Used to calculate dynamic priority
- Reset to parent's estcpu on fork (with optional bias)

**pctcpu** - Percentage CPU:
- Short-term CPU usage metric (over last second)
- Used by ps(1) to display %CPU
- Decayed more rapidly than estcpu
- Updated by `updatepcpu()` when sampled

---

## Priority and Scheduling Classes

### Priority Ranges

DragonFly uses a unified priority space:

```
0-127:     Realtime (highest)
128-255:   Normal (timesharing)
256-383:   Idle
384-511:   Kernel threads
512+:      Special/NULL
```

**Internal representation:**
- `lp->lwp_priority` - Calculated scheduling priority (0-511)
- `lp->lwp_rtprio.type` - Scheduling class (REALTIME, NORMAL, IDLE, etc.)
- `lp->lwp_rtprio.prio` - Priority within class
- `td->td_upri` - LWKT priority (negated for proper ordering)

### Priority Inversion

LWKT priorities have inverted sense (lower number = higher priority) compared to user priorities (higher number = higher priority):

```c
td->td_upri = -lp->lwp_priority;
```

This allows LWKT's queue ordering to work correctly.

### Real-time Scheduling

Real-time threads (FIFO and RR) have strict priority:
- Always run before normal/idle threads
- FIFO runs until it blocks or is preempted by higher-priority RT thread
- RR is preempted after a quantum (round-robin interval) by same-priority RT threads

**Caution:** Real-time threads can starve normal threads. Use carefully.

### Nice Value

The traditional Unix nice value (-20 to +19):
- Stored in `lp->lwp_rtprio.prio` for NORMAL class
- Lower nice = higher priority
- Maps to priority via: `pri += nice * NICEPPQ`
- Set via `setpriority(2)` syscall

---

## Best Practices

### Choosing a Scheduler

**Use DFLY (default) when:**
- Many CPUs (>= 8)
- IPC-heavy workloads (e.g., build systems)
- NUMA systems
- Need good scalability

**Use BSD4 when:**
- Few CPUs (<= 4)
- Simple workloads
- Debugging scheduler issues (simpler code)
- Prefer traditional BSD behavior

### Setting Priorities

**Real-time priorities:**
- Use sparingly - can starve normal processes
- Suitable for hard real-time control tasks
- Ensure RT tasks yield or block regularly
- Test thoroughly under load

**Nice values:**
- Adjust nice for batch jobs (`nice +10`)
- Use negative nice for interactive/important tasks (requires privilege)
- Typical range: -5 to +10

### CPU Affinity

**When to use:**
- Threads with shared data (keep on nearby CPUs)
- Real-time tasks (eliminate migration latency)
- NUMA systems (pin to node with memory)

**When NOT to use:**
- General workloads (scheduler does better job)
- Short-lived processes
- When load distribution is important

---

## Tunables and Sysctls

### BSD4 Scheduler

- `kern.usched_bsd4_rrinterval` - Round-robin interval (default: 10)
- `kern.usched_bsd4_decay` - estcpu decay rate (default: 8)
- `kern.usched_bsd4_batch_time` - Batch process threshold
- `kern.usched_bsd4_upri_affinity` - Affinity threshold
- `debug.bsd4_scdebug` - Debug PID

### DFLY Scheduler

- `kern.usched_dfly_weight1` - Current CPU affinity (default: 30)
- `kern.usched_dfly_weight2` - IPC locality (default: 180)
- `kern.usched_dfly_weight3` - Queue length penalty (default: 10)
- `kern.usched_dfly_weight4` - CPU availability (default: 120)
- `kern.usched_dfly_weight5` - NUMA memory (default: 50)
- `kern.usched_dfly_features` - Feature flags (default: 0x2f)
- `kern.usched_dfly_rrinterval` - Round-robin interval (default: 10)
- `kern.usched_dfly_decay` - estcpu decay (default: 8)
- `kern.usched_dfly_forkbias` - Fork estcpu bias (default: 1)

### General Scheduling

- `kern.pctcpu_decay` - pctcpu decay rate (default: 10)
- `kern.fscale` - Fixed-point scale factor (FSCALE = 2048)
- `kern.slpque_tablesize` - Sleep queue hash table size

---

## Summary

DragonFly's scheduling system is a sophisticated two-layer design:

1. **Sleep/wakeup** provides efficient thread blocking and synchronization
2. **Pluggable user schedulers** implement diverse scheduling policies
3. **BSD4** offers traditional simplicity for smaller systems
4. **DFLY** provides advanced scalability and topology awareness for modern hardware
5. **Extensive tunables** allow customization for specific workloads

The system balances:
- Responsiveness vs. overhead
- Cache affinity vs. load balance
- Simplicity vs. scalability

Understanding the scheduler is crucial for:
- Performance tuning
- Real-time system design
- Debugging scheduling issues
- Kernel development

Key takeaways:
- Start with DFLY defaults on multi-CPU systems
- Use BSD4 for simplicity on small systems
- Reserve realtime priorities for critical tasks
- Let the scheduler manage CPU affinity for most workloads
- Monitor context switches and load average
- Tune weights cautiously based on specific problems

The DragonFly schedulers represent years of evolution and optimization, providing excellent out-of-the-box performance while remaining tunable for specialized needs.
