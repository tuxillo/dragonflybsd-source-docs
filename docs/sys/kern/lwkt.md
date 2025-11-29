# LWKT Threading

LWKT (Lightweight Kernel Threading) is DragonFly BSD's unique message-passing based concurrency model. It is the architectural foundation that distinguishes DragonFly from traditional BSD systems and is essential to understand before exploring any other kernel subsystem.

## Overview

LWKT implements a **message-passing** threading model designed for multiprocessor scalability. Instead of relying primarily on locks to protect shared data, DragonFly uses:

- **Message passing** between threads via message ports
- **Serializing tokens** that can be held across blocking operations
- **Per-CPU thread schedulers** that minimize cross-CPU synchronization
- **Inter-processor interrupt queues (IPIQs)** for cross-CPU communication

### Why LWKT Exists

Traditional BSD kernels use pervasive locking (mutexes, spinlocks, read-write locks) to protect shared data structures in multiprocessor environments. This approach suffers from:

- **Lock contention** — Multiple CPUs waiting for the same lock
- **Cache-line bouncing** — Locks ping-pong between CPU caches
- **Priority inversion** — Lower-priority threads holding locks needed by higher-priority threads
- **Deadlock potential** — Complex lock ordering requirements

DragonFly's LWKT addresses these issues by:

- **Minimizing shared state** — Each CPU has its own scheduler and thread queues
- **Using message passing** — Threads communicate via asynchronous messages instead of shared memory
- **Allowing tokens across sleeps** — Tokens don't have the strict semantics of traditional locks
- **Deferring to thread owner** — Operations on a thread are sent as messages to its owning CPU

###Where LWKT Fits in the Architecture

LWKT is the **lowest-level** threading abstraction in DragonFly. It sits below:

- Process/LWP management (`kern_proc.c`, `kern_fork.c`, etc.)
- CPU scheduling policies (`usched_*.c`)
- All kernel subsystems (VFS, VM, networking, etc.)

Everything in the kernel runs in the context of an LWKT thread. Even interrupt handlers run as threads in DragonFly.

## Key Concepts

### Threads vs Processes

In DragonFly:

- **Thread** (`struct thread`) — The basic unit of execution in LWKT
- **LWP** (`struct lwp`) — Light Weight Process, represents a user-level thread of execution
- **Process** (`struct proc`) — A collection of LWPs sharing an address space and resources

An LWKT thread may be:

- A **kernel thread** (no associated LWP or process)
- A **user thread** (has an associated LWP and process)

All execution happens via LWKT threads. User threads enter the kernel via system calls, traps, or signals and execute in kernel mode using their LWKT thread context.

### Message Passing

Threads communicate via **message ports** (`lwkt_port`). Each thread has an embedded message port (`td_msgport`).

**Synchronous messaging:**
```c
// Send message, block until reply
lwkt_sendmsg(target_port, &msg);
```

**Asynchronous messaging:**
```c
// Send message, don't wait for reply
lwkt_sendmsg_async(target_port, &msg);
// ... do other work ...
// Later, check for reply
lwkt_waitmsg(&msg, 0);
```

Messages (`struct lwkt_msg`) contain:

- Target and reply ports
- Result fields (error code, return value)
- State flags (DONE, REPLY, QUEUED, SYNC, etc.)

### Tokens: Serialization Without Traditional Locking

**Tokens** (`struct lwkt_token`) are DragonFly's primary synchronization primitive. They differ fundamentally from traditional locks:

**Traditional locks (mutexes, spinlocks):**
- Must be released before blocking
- Strict acquire/release semantics
- Can deadlock if ordering is incorrect
- Cause cache-line bouncing

**DragonFly tokens:**
- **Can be held across blocking operations**
- Automatically released on sleep, reacquired on wakeup
- **Cannot deadlock** regardless of acquisition order
- Serialization only effective while thread is running

**Example:**
```c
lwkt_gettoken(&mp->mnt_token);  // Acquire token

// Can safely sleep here!
// Token is temporarily released, reacquired on wakeup
tsleep(wchan, 0, "wait", 0);

// Still holding token after wakeup
lwkt_reltoken(&mp->mnt_token);
```

The key insight: tokens provide **logical serialization** rather than physical lock-holding. If you block, another thread may run and access the same data, but it will also hold the token, maintaining serialization.

### Token Types

Tokens support two acquisition modes:

- **Exclusive** — Only one thread at a time (TOK_EXCLUSIVE bit set)
- **Shared** — Multiple threads simultaneously (reference count in `t_count`)

Multiple exclusive acquisitions by the same thread are allowed and tracked.

### Per-CPU Scheduling

Each CPU has its own **thread scheduler**:

- Thread queues are per-CPU (`gd_tdrunq`, `gd_tdallq`)
- Switching threads on the same CPU requires **only a critical section**
- No locks or cross-CPU synchronization for local scheduling

To schedule a thread on another CPU, use **IPIQs** (see below).

### IPIQs: Inter-Processor Interrupt Queues

When one CPU needs to operate on a thread owned by another CPU, it sends a message via an **IPIQ** (`struct lwkt_ipiq`):

- Lock-free circular buffer (FIFO)
- Source CPU writes functions to execute
- Target CPU processes them in interrupt context
- Used for cross-CPU thread migration, scheduling, etc.

**Example:** To schedule a thread on CPU 1 from CPU 0:
1. CPU 0 writes a scheduling function to CPU 1's IPIQ
2. CPU 0 sends an inter-processor interrupt (IPI) to CPU 1
3. CPU 1 handles the IPI, processes the IPIQ entry
4. CPU 1 adds the thread to its local run queue

### Critical Sections

**Critical sections** prevent preemption and must be used carefully:

```c
crit_enter();
// Cannot be preempted here
// Keep this SHORT!
crit_exit();
```

Critical sections do **not** prevent interrupts, but LWKT threads (including interrupt threads) will not preempt code in a critical section on the same CPU.

### Thread Ownership

A thread is **owned by the CPU** in its `td_gd` (globaldata) field. Only the owning CPU can directly manipulate the thread. Other CPUs must use:

- **IPIQs** to send requests to the owning CPU
- **Messaging** to communicate with the thread

This ownership model eliminates many locking requirements.

## Data Structures

### `struct thread`

Defined in `sys/sys/thread.h`. Key fields:

```c
struct thread {
    TAILQ_ENTRY(thread) td_threadq;   // Queue linkage (run/sleep/etc.)
    TAILQ_ENTRY(thread) td_allq;      // Link in gd_tdallq
    lwkt_port td_msgport;             // Built-in message port
    
    struct lwp *td_lwp;                // Associated LWP (if user thread)
    struct proc *td_proc;              // Associated process (if user thread)
    struct pcb *td_pcb;                // Process control block, top of kstack
    struct globaldata *td_gd;          // Owning CPU's globaldata
    
    const char *td_wmesg;              // Reason for blocking
    const volatile void *td_wchan;     // Wait channel
    int td_pri;                        // Priority (0-31, 31=highest)
    int td_critcount;                  // Critical section nesting count
    u_int td_flags;                    // TDF_* flags
    
    char *td_kstack;                   // Kernel stack base
    int td_kstack_size;                // Kernel stack size
    char *td_sp;                       // Saved stack pointer for context switch
    
    thread_t (*td_switch)(struct thread *); // Context switch function
    
    lwkt_tokref_t td_toks_have;        // Tokens currently held
    lwkt_tokref_t td_toks_stop;        // Tokens to acquire
    struct lwkt_tokref td_toks_array[LWKT_MAXTOKENS];
    
    char td_comm[MAXCOMLEN+1];         // Thread name
    struct ucred *td_ucred;            // Credentials (synchronized from proc)
    
    struct md_thread td_mach;          // Machine-dependent state
};
```

**Important fields:**

- `td_gd` — Identifies the owning CPU
- `td_msgport` — Every thread has a built-in message port
- `td_toks_have` / `td_toks_stop` — Token stack for serialization
- `td_pri` — Determines scheduling priority
- `td_critcount` — Critical section depth (>0 means non-preemptible)
- `td_switch` — Function pointer for machine-dependent context switching

### `struct lwkt_msg`

Defined in `sys/sys/msgport.h`. Messages sent between threads:

```c
struct lwkt_msg {
    TAILQ_ENTRY(lwkt_msg) ms_node;    // Queue linkage
    lwkt_port_t ms_target_port;       // Current target port
    lwkt_port_t ms_reply_port;        // Reply sent here
    
    void (*ms_abortfn)(struct lwkt_msg *);  // Abort handler
    int ms_flags;                     // MSGF_* flags
    int ms_error;                     // Error code (0 = success)
    
    union {
        void *ms_resultp;             // Pointer result
        int ms_result;                // Integer result
        long ms_lresult;              // Long result
        __int64_t ms_result64;        // 64-bit result
        __off_t ms_offset;            // Offset result
    } u;
    
    void (*ms_receiptfn)(struct lwkt_msg *, lwkt_port_t);
};
```

**Message flags** (`ms_flags`):

- `MSGF_DONE` — Message complete
- `MSGF_REPLY` — Message is a reply
- `MSGF_QUEUED` — Queued on a port
- `MSGF_SYNC` — Synchronous (caller blocked)
- `MSGF_INTRANSIT` — Being passed via IPI
- `MSGF_ABORTABLE` — Can be aborted
- `MSGF_PRIORITY` — High-priority message

### `struct lwkt_port`

Message ports for receiving messages:

```c
struct lwkt_port {
    lwkt_msg_queue mp_msgq;           // Normal priority messages
    lwkt_msg_queue mp_msgq_prio;      // High priority messages
    int mp_flags;                     // Port flags
    int mp_cpuid;                     // CPU affinity
    
    union {
        struct spinlock spin;         // Spinlock-protected port
        struct lwkt_serialize *serialize;  // Serializer-protected
        void *data;                   // Or custom data
    } mp_u;
    
    struct thread *mpu_td;            // Owning thread (if thread port)
    
    // Port operations (function pointers):
    void (*mp_putport)(lwkt_port_t, lwkt_msg_t);
    int (*mp_waitmsg)(lwkt_msg_t, int);
    void *(*mp_waitport)(lwkt_port_t, int);
    void (*mp_replyport)(lwkt_port_t, lwkt_msg_t);
    int (*mp_dropmsg)(lwkt_port_t, lwkt_msg_t);
};
```

### `struct lwkt_token`

Serializing tokens:

```c
struct lwkt_token {
    long t_count;                     // Shared count | EXCLUSIVE | EXCLREQ
    struct lwkt_tokref *t_ref;        // Exclusive holder reference
    long t_collisions;                // Contention counter
    const char *t_desc;               // Descriptive name
};
```

**Token states** (encoded in `t_count`):

- `TOK_EXCLUSIVE` (bit 0) — Exclusively held
- `TOK_EXCLREQ` (bit 1) — Exclusive request pending
- Count (bits 2+) — Number of shared holders (shifted by `TOK_INCR`)

### `struct lwkt_tokref`

Token reference (thread's token stack entry):

```c
struct lwkt_tokref {
    lwkt_token_t tr_tok;              // Token being held
    long tr_count;                    // TOK_EXCLUSIVE or 0
    struct thread *tr_owner;          // Thread holding this ref
};
```

Each thread has an array of `LWKT_MAXTOKENS` (32) token references, allowing nested token acquisition.

### `struct lwkt_ipiq`

Inter-processor interrupt queue:

```c
struct lwkt_ipiq {
    int ip_rindex;                    // Read index (target CPU updates)
    int ip_xindex;                    // Completion index (target updates)
    int ip_windex;                    // Write index (source CPU updates)
    int ip_drain;                     // Drain source limit
    
    struct {
        ipifunc3_t func;              // Function to execute
        void *arg1;                   // First argument
        int arg2;                     // Second argument
        char filler[32 - ...];        // Cache-line alignment
    } ip_info[MAXCPUFIFO];            // Circular buffer (256 entries)
};
```

Lock-free design:
- Source CPU writes to `ip_windex` slot
- Target CPU reads from `ip_rindex`
- No locks needed due to single-writer, single-reader pattern

## Key Functions

### Thread Management

#### `lwkt_init_thread()`
Initialize a new LWKT thread structure.

- **Purpose:** Set up thread structure, allocate kernel stack, initialize message port
- **Called by:** `lwkt_alloc_thread()`, kernel thread creation routines
- **Parameters:** `thread_t td, void *stack, int stksize, int flags, struct globaldata *gd`

#### `lwkt_alloc_thread()`
Allocate and initialize a new LWKT thread.

- **Purpose:** Allocate memory for thread structure and kernel stack
- **Returns:** Initialized `thread_t`
- **Called by:** `lwkt_create()`, process/thread creation code

#### `lwkt_switch()`
Low-level context switch between threads.

- **Purpose:** Save current thread context, restore next thread context
- **Called by:** Scheduler when switching threads
- **Critical section:** Must be called within a critical section

#### `lwkt_schedule_self()`
Deschedule current thread (voluntary sleep).

- **Purpose:** Place current thread on specified queue, switch to next runnable thread
- **Called by:** `tsleep()`, `lwkt_deschedule_self()`, any code voluntarily blocking
- **Note:** Thread will resume when rescheduled by another CPU via `lwkt_schedule()`

#### `lwkt_schedule()`
Schedule a thread for execution.

- **Purpose:** Add thread to its CPU's run queue
- **Cross-CPU:** If thread is on another CPU, uses IPIQ to send scheduling request
- **Called by:** Wakeup routines, thread creation, message completion

### Message Passing

#### `lwkt_sendmsg()`
Send a synchronous message (block until reply).

- **Purpose:** Send message to target port, block waiting for reply
- **Returns:** Error code from message (`ms_error`)
- **Typical use:** Synchronous RPC-style operations

#### `lwkt_sendmsg_async()`
Send an asynchronous message (don't wait).

- **Purpose:** Initiate message send, return immediately
- **Note:** Caller must later call `lwkt_waitmsg()` or check `MSGF_DONE`

#### `lwkt_waitmsg()`
Wait for message completion.

- **Purpose:** Block until message reply is received
- **Parameters:** `lwkt_msg_t msg, int flags`
- **Returns:** Error code

#### `lwkt_replymsg()`
Reply to a received message.

- **Purpose:** Send reply back to originating port
- **Called by:** Message handler after processing request

#### `lwkt_initmsg()`
Initialize a message structure.

- **Purpose:** Set up message for sending
- **Parameters:** `lwkt_msg_t msg, lwkt_port_t rport, int flags`

### Token Operations

#### `lwkt_gettoken()`
Acquire a token (exclusive by default).

- **Purpose:** Serialize access to protected data
- **Blocking:** Spins if token unavailable, may deschedule on contention
- **Can be called multiple times** (token stack)
- **Held across sleep:** Token automatically released/reacquired

#### `lwkt_reltoken()`
Release a token.

- **Purpose:** Release the most recently acquired token
- **Must match acquisition** (tokens released in reverse order of acquisition)

#### `lwkt_gettoken_shared()`
Acquire a shared (read) token.

- **Purpose:** Allow multiple concurrent readers
- **Blocks if:** Exclusive holder or exclusive request pending

#### `lwkt_token_pool_lookup()`
Look up a token from a token pool.

- **Purpose:** Get a token for a specific object from a pool of tokens
- **Used by:** Subsystems that need many tokens (e.g., vnodes)

### IPIQ Operations

#### `lwkt_send_ipiq()`
Send a function to execute on another CPU.

- **Purpose:** Cross-CPU operation request
- **Parameters:** `globaldata *gd, ipifunc_t func, void *arg`
- **Non-blocking:** Queues function in target CPU's IPIQ
- **Returns:** 0 on success, error if IPIQ full

#### `lwkt_process_ipiq()`
Process pending IPIQs.

- **Purpose:** Execute functions queued in local CPU's IPIQ
- **Called by:** IPI interrupt handler, scheduler
- **Runs in interrupt context**

#### `lwkt_synchronous_ipiq()`
Send IPIQ and wait for completion.

- **Purpose:** Execute function on remote CPU, wait for it to finish
- **Blocking:** Waits for target CPU to process the request

### Port Operations

#### `lwkt_initport_thread()`
Initialize a thread's built-in port.

- **Purpose:** Set up thread's message port for receiving messages
- **Called by:** `lwkt_init_thread()`

#### `lwkt_waitport()`
Wait for a message to arrive on a port.

- **Purpose:** Block until message received
- **Returns:** Pointer to received message

#### `lwkt_getport()`
Get next message from port (non-blocking).

- **Purpose:** Dequeue message if available
- **Returns:** Message or NULL if queue empty

## Subsystem Interactions

### With the Scheduler

LWKT provides the low-level threading mechanism; the scheduler determines **which** thread to run:

- Scheduler calls `lwkt_switch()` to context-switch
- Threads have priorities (`td_pri`) used by scheduler
- Per-CPU run queues (`gd_tdrunq`) hold runnable threads
- Scheduler policies (`usched_dfly`, `usched_bsd4`) implement different algorithms on top of LWKT

See [Scheduling](scheduling.md) for details.

### With Processes and LWPs

User threads are LWKT threads with attached LWP and process structures:

- System calls execute in user thread's LWKT context
- Process creation (`fork()`) creates new LWKT threads
- Thread exit releases LWKT thread structure

See [Processes & Threads](processes.md) for details.

### With the Virtual Filesystem (VFS)

VFS uses tokens extensively for serialization:

- Mount points have tokens (`mnt_token`)
- Vnodes use token pools
- Buffer cache operations hold tokens
- Token semantics allow sleeping during I/O

See [VFS](vfs/index.md) for details.

### With Device Drivers

Drivers often use:

- **Serializers** (`lwkt_serialize`) for interrupt synchronization
- **Tokens** for driver-internal serialization
- **Message ports** for async operations

Device interrupt threads run as LWKT threads, allowing uniform scheduling.

### With the VM System

VM operations:

- Use tokens to protect VM objects and maps
- May block during page-ins (tokens held across sleep)
- Page daemon runs as an LWKT kernel thread

## Code Flow Examples

### Example 1: Thread Creation and Scheduling

```c
// Create a new kernel thread
thread_t td;

td = lwkt_alloc_thread(NULL, LWKT_THREAD_STACK, -1, TDF_MPSAFE);
lwkt_init_thread(td, stack, stksize, 0, my_gd);
td->td_flags |= TDF_MPSAFE;
bcopy("mythrd", td->td_comm, sizeof("mythrd"));

// Set up to run a function
cpu_set_thread_handler(td, my_thread_fn, arg);

// Schedule it for execution
lwkt_schedule(td);  // Will run on td->td_gd CPU
```

**Flow:**
1. Allocate thread structure
2. Initialize (stack, message port, globaldata)
3. Set up machine state to call `my_thread_fn`
4. Add to run queue via `lwkt_schedule()`
5. Scheduler eventually switches to new thread

### Example 2: Synchronous Message Send

```c
struct lwkt_msg msg;

// Initialize message
lwkt_initmsg(&msg, &my_reply_port, 0);

// Send to target, block until reply
int error = lwkt_sendmsg(target_port, &msg);

// Message has been processed, result in msg.ms_error or msg.u.*
if (error == 0) {
    result = msg.u.ms_result;
}
```

**Flow:**
1. Caller initializes message with reply port
2. `lwkt_sendmsg()` calls target port's `mp_putport()` function
3. Target port queues message (or processes immediately)
4. Caller blocks waiting for reply (`MSGF_SYNC` set)
5. Target processes message, calls `lwkt_replymsg()`
6. Reply wakes up caller, caller returns with result

### Example 3: Token Acquisition Across Sleep

```c
// Acquire token
lwkt_gettoken(&vp->v_token);

// Safe to access vnode fields here

// Need to sleep waiting for I/O
tsleep(&bp->b_flags, 0, "biowait", 0);
// Token is temporarily released during sleep
// Token is reacquired before tsleep() returns

// Still holding token, safe to access vnode
lwkt_reltoken(&vp->v_token);
```

**Flow:**
1. `lwkt_gettoken()` acquires token
2. Code accesses protected data
3. `tsleep()` deschedules thread, saves token stack
4. While asleep, another thread may acquire the same token
5. On wakeup, `tsleep()` reacquires all tokens before returning
6. Code continues with token held
7. `lwkt_reltoken()` releases token

### Example 4: Cross-CPU Scheduling via IPIQ

CPU 0 wants to schedule a thread owned by CPU 1:

```c
// On CPU 0, scheduling thread td (owned by CPU 1)
lwkt_schedule(td);
```

**Internal flow:**
1. `lwkt_schedule()` checks `td->td_gd` (= CPU 1's globaldata)
2. Sees thread is on another CPU
3. Calls `lwkt_send_ipiq(cpu1_gd, lwkt_schedule_remote, td)`
4. Writes `{lwkt_schedule_remote, td}` to CPU 1's IPIQ
5. Sends inter-processor interrupt to CPU 1
6. CPU 1 handles IPI, calls `lwkt_process_ipiq()`
7. `lwkt_process_ipiq()` executes `lwkt_schedule_remote(td)`
8. `lwkt_schedule_remote()` adds `td` to CPU 1's run queue

## Traditional BSD vs DragonFly LWKT

### Traditional BSD Approach

```c
// Traditional: Acquire lock, access data, release lock
mtx_lock(&vp->v_lock);
// Cannot sleep here!
// Access v_data
mtx_unlock(&vp->v_lock);
```

**Problems:**
- Locks must be released before sleeping
- Complex code to handle sleep/wakeup with locks
- Lock ordering requirements to avoid deadlock
- Cache-line bouncing on multiprocessor systems

### DragonFly LWKT Approach

```c
// DragonFly: Acquire token, access data, can sleep, release token
lwkt_gettoken(&vp->v_token);
// Can sleep here!
tsleep(wchan, 0, "vnode", 0);
// Still serialized after wakeup
// Access v_data
lwkt_reltoken(&vp->v_token);
```

**Advantages:**
- Tokens held across sleep (simpler code)
- No deadlock possibility (tokens can be acquired in any order)
- Per-CPU scheduling (no global scheduler lock)
- Message passing reduces shared state

### Multiprocessor Scalability

**Traditional approach:**
- Global scheduler lock contended by all CPUs
- Locks on shared data structures (e.g., vnodes, sockets)
- Cache coherency overhead

**LWKT approach:**
- Per-CPU scheduling (no global lock)
- Message passing instead of shared state
- Tokens reduce contention (logical serialization)
- Thread ownership eliminates many locks

## Important Notes

### Token Deadlock Freedom

Tokens **cannot deadlock** because:

1. **Held across sleep:** If you block waiting for a resource, your token is released
2. **Any ordering:** Tokens can be acquired in any order
3. **Priority boosting:** Token contention can boost thread priority

Traditional locks **can deadlock** because they must be held continuously and have strict ordering requirements.

### When to Use What

- **Tokens:** Subsystem-level serialization (e.g., entire mount point, vnode)
- **Spinlocks:** Very short critical sections, interrupt context
- **Serializers:** Device driver interrupt/thread synchronization
- **Messages:** Cross-CPU operations, async work queuing

### Performance Considerations

- **Critical sections must be short** — Prevent preemption, don't abuse
- **IPIQs are bounded** — Can fill up if target CPU is busy
- **Token contention** — Tracked in `t_collisions`, can indicate bottleneck

## Files

Key source files implementing LWKT:

- `sys/kern/lwkt_thread.c` — Thread management, scheduling, context switching
- `sys/kern/lwkt_msgport.c` — Message ports and message passing
- `sys/kern/lwkt_token.c` — Serializing tokens
- `sys/kern/lwkt_ipiq.c` — Inter-processor interrupt queues
- `sys/kern/lwkt_serialize.c` — Serializer helpers (for drivers)

Key header files:

- `sys/sys/thread.h` — `struct thread`, token structures
- `sys/sys/msgport.h` — `struct lwkt_msg`, `struct lwkt_port`
- `sys/sys/thread2.h` — Inline functions, macros

## References

- [Synchronization](synchronization.md) — Other synchronization primitives (spinlocks, mutexes, etc.)
- [Scheduling](scheduling.md) — CPU scheduling policies built on LWKT
- [Processes & Threads](processes.md) — Process and LWP management using LWKT
- [VFS](vfs/index.md) — Extensive use of tokens for filesystem serialization
- [IPC & Sockets](ipc.md) — Message passing used in socket layer

## Further Reading

DragonFly's LWKT is unique among BSD systems. Understanding it is essential for kernel development. Key concepts to remember:

1. **Message passing over shared memory**
2. **Tokens held across sleep**
3. **Per-CPU scheduling**
4. **Thread ownership by CPU**
5. **Deadlock-free by design**

These principles enable DragonFly's superior multiprocessor scalability compared to traditional BSD kernels.
