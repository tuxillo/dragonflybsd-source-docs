# Process and Thread Management

This document describes the complete lifecycle of processes and threads in DragonFly BSD, from creation through execution to termination and cleanup.

## Overview

DragonFly BSD has a three-level threading model:

1. **Processes** (`struct proc`) - Traditional BSD process containers
2. **LWPs** (Light Weight Processes, `struct lwp`) - Kernel-visible threads
3. **LWKT threads** (`struct thread`) - Lightweight kernel threads

User processes contain one or more LWPs, each with an associated LWKT thread. Pure kernel threads exist as LWKT threads without an associated process or LWP.

**Key source files:**
- `kern_proc.c` - Process table management, PID allocation, lookups
- `kern_fork.c` - Process/thread creation (fork, rfork, lwp_create)
- `kern_exec.c` - Program execution (execve)
- `kern_exit.c` - Process termination and cleanup
- `kern_kthread.c` - Kernel thread creation

## Process Table and PID Management

### Data Structures

The kernel maintains several global lists for process tracking:

```c
// Active processes - hash table with 256 buckets
#define ALLPROC_HSIZE 256
static struct procglob allproc_hash[ALLPROC_HSIZE];

// Zombie processes - single list
static struct procglob zombproc_list;

// PID domain tracking (prevents rapid reuse)
#define PIDDOM_DELAY 10
static pid_t pid_doms[PIDDOM_DELAY];
```

Each `procglob` entry contains:
- `allproc` - List head for active or zombie processes
- `lock` - Spinlock protecting the list

### PID Allocation

PID allocation (`kern_proc.c:proc_getnewpid()`) includes security features to prevent predictability:

1. **Random offset** - Start PID counter at random value modulo PID_MAX
2. **Anti-reuse** - Track last 10 PIDs in `pid_doms[]`, prevent reuse for ~10 seconds
3. **Hash bucket optimization** - Increment by ALLPROC_HSIZE (256) to keep process in same hash bucket for better cache locality

```c
newpid += ALLPROC_HSIZE;  // Stay in same hash bucket
if (newpid >= PID_MAX) {
    newpid = newpid % ALLPROC_HSIZE;
    newpid += ALLPROC_HSIZE;
}
```

The algorithm checks:
- PID not already in use (`pfind()`)
- PID not recently freed (within PIDDOM_DELAY seconds)
- PID not in session/process group use

### Process Reference Counting

Processes use atomic reference counting via `p_lock` with multiple flag bits:

```c
#define PLOCK_MASK     0x1fffffff  // Reference count
#define PLOCK_WAITING  0x20000000  // Someone waiting for lock
#define PLOCK_ZOMB     0x40000000  // Zombie being reaped
#define PLOCK_WAITRES  0x80000000  // Waiting for resources
```

**Reference count macros:**
- `PHOLD(p)` / `PRELE(p)` - General purpose reference counting
- `PHOLDZOMB(p)` / `PRELEZOMB(p)` - Exclusive zombie reaping (sets PLOCK_ZOMB)
- `PWAITRES(p)` / `PWAKEUP(p)` - Resource wait coordination

The reference count prevents a process structure from being freed while in use. Zombie processes remain in the table with p_stat=SZOMB until the parent reaps them via wait().

### Process Lookup Functions

```c
struct proc *pfind(pid_t pid);           // Find active process
struct proc *zpfind(pid_t pid);          // Find zombie process
struct proc *pgfind(pid_t pgid);         // Find process group leader
struct lwp *lwpfind(struct proc *p, lwpid_t lwpid);  // Find LWP by ID
```

All lookup functions:
- Acquire the appropriate hash bucket spinlock
- Return process/LWP with reference count held (PHOLD)
- Caller must release with PRELE when done

### Process Iteration

```c
int allproc_scan(int (*callback)(struct proc *, void *), void *data, int flags);
int zombproc_scan(int (*callback)(struct proc *, void *), void *data, int flags);
```

Flags control behavior:
- `PFSCAN_NOBRK` - Don't break on non-zero callback return
- `PFSCAN_LOCKED` - Keep process locked during callback (PHOLD)

These functions are used by system utilities (ps, top) and kernel subsystems that need to enumerate all processes.

## Process Creation: fork()

### System Call Entry Points

```c
int sys_fork(struct sysmsg *);          // Traditional fork
int sys_vfork(struct sysmsg *);         // vfork (shared memory)
int sys_rfork(struct sysmsg *, struct rfork_args *);  // Extended fork
```

All fork variants funnel through `fork1()` with different flag combinations:

**RFORK flags:**
- `RFPROC` - Create new process (required)
- `RFMEM` - Share address space (for vfork or threads)
- `RFFDG` - Share file descriptor table
- `RFCFDG` - Close file descriptors (exclusive with RFFDG)
- `RFSIGSHARE` - Share signal handlers
- `RFTHREAD` - Create thread (LWP) in current process
- `RFPPWAIT` - Parent sleeps until child releases vmspace (vfork)
- `RFENVG` - Create new environment group
- `RFCENVG` - Close environment variables

### fork1() Overview

The main fork implementation (`kern_fork.c:fork1()`) performs these steps:

1. **Preparation**
   - Validate flags (RFPROC required, mutual exclusions)
   - Check resource limits (RLIMIT_NPROC)
   - Account for new process in uid structure

2. **Process structure allocation**
   - Allocate `struct proc` via `kmalloc()`
   - Initialize reference count, locks, lists
   - Insert into `allproc` hash table
   - Allocate PID via `proc_getnewpid()`

3. **Process setup**
   - Copy or share credentials based on flags
   - Copy or share file descriptor table
   - Copy or share signal handler table
   - Set process state to SIDL (intermediate)

4. **LWP creation** (two-phase)
   - `lwp_fork1()` - Allocate LWP structure, prepare for vm_fork
   - `vm_fork()` - Handle address space (copy-on-write or share)
   - `lwp_fork2()` - Finalize LWP, insert into process

5. **Finalization**
   - Call `at_fork()` registered callbacks
   - Set up parent/child relationship
   - For RFPPWAIT (vfork): parent sleeps until child execs or exits

6. **Activation**
   - `start_forked_proc()` transitions child from SIDL to SACTIVE
   - Child LWP becomes schedulable

### Two-Phase LWP Creation

The fork process splits LWP creation around `vm_fork()`:

**Phase 1: lwp_fork1()** (`kern_fork.c:lwp_fork1()`)
- Allocates `struct lwp`
- Allocates kernel stack via `lwkt_alloc_thread()`
- Initializes basic fields (proc pointer, flags)
- **Does not insert into p_lwp_tree yet**

**VM Fork: vm_fork()** (in vm subsystem)
- Sets up address space for child process
- Creates COW (copy-on-write) mappings for non-shared pages
- For RFMEM: shares vmspace directly (vfork, threads)
- Handles special mappings (shared memory, mmap)

**Phase 2: lwp_fork2()** (`kern_fork.c:lwp_fork2()`)
- Completes machine-dependent setup via `cpu_lwp_fork()`
- Sets initial register state (return value, stack pointer)
- **Inserts LWP into `p_lwp_tree`** (RB tree indexed by lwpid)
- Sets LWP state to LSSTOP (not running yet)

This two-phase design ensures the LWP is not visible to the rest of the system (via p_lwp_tree) until the address space is properly set up.

### Starting the Forked Process

```c
void start_forked_proc(struct lwp *parent, struct proc *child)
```

This function transitions the child process to runnable state:

1. Acquire process token
2. Transition from SIDL to SACTIVE state
3. Transition LWP from LSSTOP to LSRUN
4. Schedule the child's thread via `lwkt_schedule()`
5. Child will return from fork with retval=0 (vs parent getting child PID)

### vfork() Coordination

When `RFPPWAIT` is set (vfork):

1. Parent process blocks in `fork1()` after starting child
2. Parent waits on `p_ppwait_cv` condition variable
3. Child signals parent when:
   - Child calls exec (in `kern_exec.c:exec_new_vmspace()`)
   - Child exits (in `kern_exit.c:exit1()`)
4. Parent wakes up and continues

This ensures the parent doesn't modify shared memory while the child is using it.

### Thread Creation: lwp_create()

User threads (pthreads) are created via:

```c
int sys_lwp_create(struct lwp_params *params);
```

This creates a new LWP within the current process:

1. Calls `lwp_create1()` to allocate LWP structure
2. Does **not** call `vm_fork()` - address space is shared
3. Sets up new stack region within shared address space
4. Sets entry point to user-specified function
5. New thread runs in parallel with existing LWPs

LWP creation is much lighter than process creation since:
- No new process structure
- No PID allocation
- No credential/fd/signal copying
- No COW setup (memory is shared)

## Process Execution: execve()

### System Call Entry

```c
int sys_execve(struct sysmsg *, struct execve_args *);
```

Arguments:
- `fname` - Path to executable
- `argv` - Argument vector (NULL-terminated)
- `envv` - Environment vector (NULL-terminated)

### Execution Overview

The `kern_execve()` function (`kern_exec.c`) replaces the current process's address space and execution context with a new program:

1. **Path resolution** - Lookup executable via `nlookup()`
2. **Permission checks** - Verify execute permission, handle setuid/setgid
3. **Image identification** - Try each image activator to identify format
4. **Point of no return** - Destroy old address space
5. **New address space setup** - Load program, build stack
6. **State reset** - Close files, reset signals, update credentials
7. **Entry** - Set PC to program entry point and return to usermode

### Preventing Concurrent Execution

Multi-threaded processes must not exec concurrently:

```c
if (p->p_flags & P_INEXEC) {
    return EBUSY;  // Another thread is already in exec
}
p->p_flags |= P_INEXEC;
```

The `P_INEXEC` flag remains set until exec completes or fails.

### Image Activators

The kernel tries each registered image activator in turn:

```c
const struct execsw execsw[] = {
    { exec_elf_imgact, "ELF" },
    { exec_resident_imgact, "resident" },
    { exec_script_imgact, "#!" },
    { NULL, NULL }
};
```

Each activator's function signature:

```c
int (*ex_imgact)(struct image_params *imgp);
```

**Image activator process:**
1. Read first page of executable (4KB)
2. Call each activator's `ex_imgact()` function
3. Activator inspects headers (ELF magic, #! shebang, etc.)
4. Return `-1` if not recognized, `0` if accepted, error code if failed
5. First activator to accept the image handles execution

### Script Execution (#!)

The script activator (`exec_script_imgact()`) handles interpreter files:

```c
#!/usr/bin/interpreter [args]
program content...
```

When detected:
1. Extract interpreter path and optional arguments from first line
2. Construct new argv: `[interpreter, args..., scriptname, original_argv...]`
3. Recursively call `kern_execve()` with interpreter as executable
4. Recursion depth limited to prevent infinite loops

### Point of No Return

```c
error = exec_new_vmspace(imgp, stack);
```

This function (`kern_exec.c:exec_new_vmspace()`) destroys the old address space:

1. Create new vmspace structure
2. If process was vfork'd (P_PPWAIT set):
   - Signal parent to wake up via `wakeup(p->p_pptr)`
   - Drop shared vmspace reference
3. Destroy old vmspace
4. Attach new vmspace to process
5. **Cannot fail after this point** - process has no valid address space to return to

### Building the New Stack

```c
error = exec_copyout_strings(imgp, &stack_base);
```

This function constructs the user stack in this order (growing downward):

```
High addresses
+------------------+
| envp strings     |
+------------------+
| argv strings     |
+------------------+
| exec path        |
+------------------+
| padding          |  (for alignment)
+------------------+
| auxv vector      |  (auxiliary vector, ELF only)
+------------------+
| NULL             |
| envp[n-1]        |  (pointers to env strings)
| ...              |
| envp[0]          |
+------------------+
| NULL             |
| argv[n-1]        |  (pointers to arg strings)
| ...              |
| argv[0]          |
+------------------+
| argc             |  (argument count)
+------------------+  <- stack pointer at program entry
Low addresses
```

**Stack gap randomization:**
- Controlled by `exec.stackgap_random` sysctl
- Randomly subtracts 0 to stackgap_random bytes from stack pointer
- Helps prevent return-to-libc attacks

**Auxiliary vector (auxv):**
ELF programs receive metadata through auxv entries:
- `AT_PHDR` - Address of program header table
- `AT_PHENT` - Size of program header entry
- `AT_PHNUM` - Number of program headers
- `AT_PAGESZ` - System page size
- `AT_BASE` - Interpreter base address (for dynamic executables)
- `AT_ENTRY` - Program entry point
- `AT_EXECPATH` - Full path to executable

### Credential Handling (setuid/setgid)

If the executable has setuid or setgid bits:

```c
if (attr.va_mode & (S_ISUID | S_ISGID)) {
    p->p_flags |= P_SUGID;  // Mark process as tainted
    // Update credentials
    if (attr.va_mode & S_ISUID)
        change_euid(attr.va_uid);
    if (attr.va_mode & S_ISGID)
        change_egid(attr.va_gid);
}
```

**P_SUGID security restrictions:**
- Prevents ptrace() attachment
- Prevents core dumps to user directories
- Restricts /proc access
- Cleared on subsequent exec of non-setuid binary

### File Descriptor Cleanup

During exec, the kernel closes file descriptors marked close-on-exec:

```c
fdcloseexec(p);  // Close all FDs with FD_CLOEXEC set
```

This is commonly used for:
- Pipe file descriptors in shell pipelines
- Internal file descriptors that shouldn't be inherited
- Library handles that need to be reopened

### Signal Handler Reset

```c
execsigs(p);
```

This function resets all signal dispositions:
- Signals set to SIG_IGN remain ignored
- Signals set to SIG_DFL remain default
- **Caught signals (custom handlers) reset to SIG_DFL**

Since the old address space is gone, signal handler function pointers are no longer valid.

### Entry to New Program

After all setup completes:

1. `exec_setregs()` sets up initial CPU state:
   - Program counter (PC) → entry point address
   - Stack pointer (SP) → top of prepared stack
   - Argument registers → argc, argv (architecture-dependent)
2. Exec system call returns to user mode
3. CPU state causes execution to begin at program entry point

For dynamically linked ELF programs, entry point is actually the dynamic linker (ld-elf.so), which:
- Loads shared libraries
- Performs relocations
- Eventually transfers control to program's actual `_start()`

## Process Termination: exit()

### System Call Entry

```c
int sys_exit(struct sysmsg *, struct exit_args *);
int sys_exit_group(struct sysmsg *, struct exit_group_args *);  // Linux compat
```

Both funnel through `exit1()` with a status code.

### exit1() Overview

The main exit implementation (`kern_exit.c:exit1()`) performs these steps:

1. **Exit coordination** - Set P_WEXIT flag to prevent concurrent exits
2. **Stop other threads** - Call `killalllwps()` to terminate all other LWPs
3. **Accounting** - Record CPU time and resource usage
4. **Cleanup** - Close files, release resources, detach from process groups
5. **Zombie transition** - Move from allproc to zombproc list
6. **Parent notification** - Send SIGCHLD to parent
7. **Thread termination** - Current LWP calls `lwp_exit()` and never returns

### Preventing Concurrent Exit

```c
if (p->p_flags & P_WEXIT) {
    lwkt_reltoken(&p->p_token);
    return;  // Already exiting
}
p->p_flags |= P_WEXIT;
```

Only the first thread to set `P_WEXIT` performs the full exit sequence. Other threads in `exit1()` simply return and get cleaned up by `killalllwps()`.

### Killing All LWPs

```c
killalllwps(int signo);
```

This function (`kern_exit.c`) terminates all other LWPs in the process:

1. Acquire proc token
2. Iterate through `p_lwp_tree` (all LWPs in process)
3. For each other LWP:
   - Set LWP state to LSZOMB
   - Post signal if specified
   - Issue `lwkt_deschedule()` to remove from scheduler
4. Wait for all LWPs to finish deschedule
5. Reap zombie LWPs

**LWP reaper mechanism:**
- Dead LWPs are added to `deadlwp_list`
- `deadlwp_task` taskqueue entry processes the list
- Each dead LWP's kernel stack is freed
- LWP structure itself is freed

This asynchronous reaping avoids freeing the kernel stack that might still be in use.

### Process Cleanup Sequence

After killing all LWPs, `exit1()` performs:

1. **Session/Process Group Cleanup**
   - If session leader: terminate controlling terminal
   - If process group leader: send SIGHUP to foreground processes
   - Remove from process group

2. **File Descriptor Cleanup**
   ```c
   fdfree(p, td);  // Close all open files
   ```
   - Closes all file descriptors
   - Releases file descriptor table
   - Decrements reference counts on file structures

3. **Virtual Memory Cleanup**
   ```c
   if (!--vmspace->vm_refcnt) {
       vmspace_dtor(vmspace);  // Last reference, free vmspace
   }
   ```
   - Decrements vmspace reference count
   - If last reference: unmaps all regions, frees page tables

4. **IPC Cleanup**
   - Remove from System V semaphore undo list
   - Detach from shared memory segments

5. **Credential Cleanup**
   ```c
   crfree(p->p_ucred);  // Release credential structure
   ```

6. **Timer Cleanup**
   - Stop ITIMER_REAL, ITIMER_VIRTUAL, ITIMER_PROF timers
   - Remove from timer queues

### Zombie Transition

```c
proc_move_allproc_zombie(struct proc *p);
```

This function (`kern_proc.c`) atomically moves the process from active to zombie state:

1. Remove from `allproc_hash[bucket]`
2. Add to `zombproc_list`
3. Set `p->p_stat = SZOMB`
4. Leave `p_nthreads` at 1 (decrement happens after parent reaps)

**Zombie state characteristics:**
- Process structure remains allocated
- PID remains allocated (in `pid_doms[]` anti-reuse list)
- Exit status preserved in `p->p_xstat`
- All other resources freed

### Parent Notification

After transition to zombie:

1. Increment parent's `p_waitgen` counter (wake optimization)
2. Send SIGCHLD to parent via `ksignal(p->p_pptr, SIGCHLD)`
3. Wakeup any threads in `wait()` via `wakeup(p->p_pptr)`

The `p_waitgen` counter allows wait() to quickly detect if any child has changed state without scanning the entire child list.

### Orphan Handling

If parent has already exited, child is reparented:

```c
proc_reparent(struct proc *child, struct proc *parent);
```

**Reparenting rules:**
1. If parent is init (PID 1): child becomes init's child
2. If process has a registered reaper: child moves to reaper
3. Otherwise: child becomes init's child

The reaper mechanism allows creating "sub-init" processes for containers or process supervision.

### Thread Exit

Finally, the exiting thread calls:

```c
lwp_exit(int masterexit, void (*exitfunc)(void *), void *exitarg);
```

This function:
1. Sets `lp->lwp_stat = LSZOMB`
2. Calls exit function if provided (for cleanup)
3. Calls `cpu_lwp_exit()` to release machine-dependent resources
4. Calls `lwkt_exit()` which:
   - Deschedules thread
   - Marks stack for deferred free
   - Switches to new thread
   - **Never returns**

### Parent Wait and Reaping

Parent processes retrieve exit status via wait():

```c
int sys_wait4(struct sysmsg *, struct wait4_args *);
```

The `kern_wait()` function (`kern_exit.c`) performs:

1. **Wait loop optimization**
   ```c
   int waitgen = p->p_waitgen;
   while (/* no matching child */) {
       tsleep_interlock(&waitgen, PCATCH);
       if (waitgen == p->p_waitgen)
           tsleep(p, PCATCH | PINTERLOCKED, "wait", 0);
       waitgen = p->p_waitgen;
   }
   ```
   The waitgen counter avoids spurious wakeups - only sleep if counter hasn't changed.

2. **Child scan**
   - Iterate through `p->p_children` list
   - Match on PID (if specified) or any child (PID -1)
   - Match on process group (if negative PID)

3. **Zombie reaping**
   ```c
   PHOLDZOMB(child);  // Exclusive access, sets PLOCK_ZOMB
   ```
   - Acquire exclusive zombie lock (prevents concurrent wait by other threads)
   - Copy exit status from `p->p_xstat`
   - Copy resource usage from `p->p_ru`
   - Remove from parent's `p_children` list
   - Call `proc_finish(child)` to free process structure

4. **Process finish**
   ```c
   proc_finish(struct proc *p);
   ```
   - Remove from zombie list
   - Decrement PID domain reference in `pid_doms[]`
   - Free process structure
   - PID becomes available for reuse after PIDDOM_DELAY

### Wait Options

The wait4() system call supports various options:

- `WNOHANG` - Return immediately if no child has exited
- `WUNTRACED` - Also return for stopped children (job control)
- `WCONTINUED` - Also return for continued children (SIGCONT)
- `WLINUXCLONE` - Linux compatibility for thread waiting

Without WNOHANG, wait() sleeps until a child changes state or a signal arrives.

## Kernel Threads

### Overview

Kernel threads are lightweight threads that run entirely in kernel mode without an associated user process or LWP. They are used for:

- Asynchronous I/O completion
- Device driver background tasks
- Network stack processing
- Virtual memory pageout daemon
- System maintenance tasks

### Creating Kernel Threads

```c
int kthread_create(void (*func)(void *), void *arg,
                   struct thread **tdp, const char *fmt, ...);
```

**Parameters:**
- `func` - Thread entry point function
- `arg` - Argument passed to function
- `tdp` - Returns pointer to created thread (can be NULL)
- `fmt` - Printf-style format for thread name (appears in ps)

**Variants:**

```c
// Create but don't schedule immediately
int kthread_alloc(void (*func)(void *), void *arg,
                  struct thread **tdp, const char *fmt, ...);

// Pin to specific CPU
int kthread_create_cpu(void (*func)(void *), void *arg,
                       struct thread **tdp, int cpu, const char *fmt, ...);
```

### Thread Creation Process

Internal function `_kthread_create()` (`kern_kthread.c`):

1. **Allocate thread structure**
   ```c
   td = lwkt_alloc_thread(NULL, LWKT_THREAD_STACK, cpu, flags);
   ```
   - Allocates `struct thread`
   - Allocates kernel stack (typically 16KB)
   - CPU parameter pins thread to specific CPU, or -1 for any CPU

2. **Set up execution context**
   ```c
   cpu_set_thread_handler(td, kthread_exit, func, arg);
   ```
   - Sets stack pointer to top of kernel stack
   - Sets up return chain: `func` returns to `kthread_exit`
   - Saves argument for function

3. **Initialize thread metadata**
   - Copy name to `td->td_comm` (visible in ps, top)
   - Share credentials with proc0 (kernel process)
   - Set `td->td_proc = NULL` to mark as pure kernel thread

4. **Schedule thread**
   ```c
   lwkt_schedule(td);
   ```
   - Only if `schedule_now` parameter is true
   - Thread becomes runnable on target CPU
   - Scheduler will run thread when appropriate

### Kernel Thread Lifecycle

**Entry:**
- Thread starts executing at `func`
- Runs at elevated privilege (kernel mode)
- Has full access to kernel memory and data structures

**Execution:**
- Thread can sleep, waiting for events
- Thread can acquire locks and access shared data
- Thread should check for termination requests

**Exit:**
- Thread returns from `func`, which chains to `kthread_exit()`
- `kthread_exit()` calls `lwkt_exit()`:
  - Marks thread as exiting
  - Deschedules from runqueue
  - Marks stack for deferred free
  - Switches to another thread
  - Never returns

### Kernel Process Creation

The `kproc_start()` function creates kernel threads via SYSINIT:

```c
struct kproc_desc {
    char *arg0;                        // Thread name
    void (*func)(void);                // Entry point
    struct thread **global_threadpp;   // Where to store thread pointer
};

void kproc_start(const void *udata);
```

**Usage:**

```c
static struct thread *mythread;

static struct kproc_desc my_kproc = {
    "mythread",
    my_thread_func,
    &mythread
};
SYSINIT(my_init, SI_SUB_KTHREAD_IDLE, SI_ORDER_ANY, kproc_start, &my_kproc);
```

This creates the kernel thread during system initialization, after core kernel threads are running.

### Kernel Thread Suspension

Kernel threads can voluntarily suspend:

```c
int suspend_kproc(struct thread *td, int timo);
void kproc_suspend_loop(void);
```

**Suspend mechanism:**

1. External code calls `suspend_kproc(td, timeout)`
2. Sets `TDF_MP_STOPREQ` flag on target thread
3. Wakes target thread (if sleeping)
4. Waits for thread to acknowledge suspension

**Thread cooperation:**

The kernel thread periodically calls:
```c
kproc_suspend_loop();  // Check if someone wants us to suspend
```

If `TDF_MP_STOPREQ` is set:
- Clear request flag
- Sleep until `TDF_MP_WAKEREQ` is set
- Clear wake flag and continue

This allows kernel threads to be paused for maintenance operations or shutdown.

## Process States and Transitions

### Process States (p_stat)

```c
#define SIDL    1   // Process being created
#define SACTIVE 2   // Process is active
#define SSTOP   3   // Process stopped (job control)
#define SZOMB   4   // Process is zombie (awaiting reaping)
```

**State transitions:**

```
     fork1()          start_forked_proc()
NULL --------> SIDL ----------------------> SACTIVE
                                               |
                                               | exit1()
                                               v
                                            SZOMB -----> freed
                                               ^      wait4()
                                               |
                                           SSTOP
                                        (via signal)
```

### LWP States (lwp_stat)

```c
#define LSRUN    1  // Runnable (on or waiting for CPU)
#define LSSTOP   2  // Stopped (job control, debugging)
#define LSSLEEP  3  // Sleeping (waiting for event)
#define LSZOMB   4  // Zombie (terminated but not reaped)
#define LSSUSPENDED 5  // Suspended (special conditions)
```

**Typical LWP lifecycle:**

```
     lwp_fork2()      scheduler        sleep event
NULL -----------> LSSTOP --------> LSRUN -----------> LSSLEEP
                           ^                             |
                           |        wakeup               |
                           +-----------------------------+
                           
                  lwp_exit()
              ---------------> LSZOMB -----> freed
                                        (deferred)
```

### Thread States (td_flags)

LWKT threads have numerous flags in `td_flags`:

```c
#define TDF_RUNNING      0x0001  // Thread on CPU
#define TDF_RUNQ         0x0002  // Thread on runqueue
#define TDF_TSLEEP       0x0004  // Thread in tsleep
#define TDF_EXITING      0x0010  // Thread exiting
#define TDF_SINTR        0x0020  // Sleep is interruptible
#define TDF_TIMEOUT      0x0040  // Timeout in progress
// ... many more
```

Threads transition between runqueue, running, sleeping states based on scheduler and synchronization events.

## Process Relationships

### Parent-Child Relationships

Each process maintains:

```c
struct proc {
    struct proc *p_pptr;           // Parent process
    struct proclist p_children;    // List of child processes
    struct sibling_entry p_sibling; // Sibling list entry
    // ...
};
```

**Invariants:**
- Every process except proc0 has a parent
- A process's children are on its `p_children` list
- Siblings are linked through `p_sibling`

### Process Groups and Sessions

```c
struct proc {
    struct pgrp *p_pgrp;          // Process group
    pid_t p_pgid;                 // Process group ID
    // ...
};

struct pgrp {
    struct proclist pg_members;    // Members of this group
    struct session *pg_session;    // Session containing this group
    pid_t pg_id;                   // Process group ID
};

struct session {
    struct pgrp_list s_groups;     // Groups in this session
    struct vnode *s_ttyvp;         // Controlling terminal
    pid_t s_sid;                   // Session ID
};
```

**Hierarchy:**

```
Session
  |
  +-- Process Group 1
  |     |
  |     +-- Process A (leader)
  |     +-- Process B
  |     +-- Process C
  |
  +-- Process Group 2
        |
        +-- Process D (leader)
        +-- Process E
```

**Purpose:**
- **Sessions** - Isolate groups of related processes (typically one per login)
- **Process Groups** - Job control (foreground/background jobs in shell)
- **Controlling Terminal** - Associated with session, receives signals (SIGINT, SIGQUIT)

Process group leaders (PID == PGID) and session leaders (PID == SID) have special responsibilities:
- Session leader death causes SIGHUP to all processes in session
- Process group leader death can cause controlling terminal loss

### Reaper Hierarchy

```c
struct proc {
    struct sysreaper *p_reaper;    // Our reaper (or NULL)
    // ...
};

struct sysreaper {
    struct proc *p;                // Reaper process
    int refs;                      // Reference count
    struct sysreaper *parent;      // Parent reaper
};
```

Reapers provide a mechanism for process supervision:

- When a process exits, orphaned children are reparented to the reaper
- If no reaper, children go to init (PID 1)
- Allows containers or supervision trees without requiring PID 1

Example hierarchy:

```
init (PID 1)
  |
  +-- reaper_daemon (reaper for container)
        |
        +-- container_process_1
        +-- container_process_2
              |
              +-- child_process
```

If `container_process_2` exits, `child_process` is reparented to `reaper_daemon`, not init.

## Process Trees and Debugging

### /proc Filesystem

The process filesystem exposes process information:

- `/proc/<pid>/status` - Process status
- `/proc/<pid>/mem` - Process memory (for debugging)
- `/proc/<pid>/map` - Memory mappings
- `/proc/<pid>/cmdline` - Command line arguments

### ptrace() System Call

```c
int sys_ptrace(struct sysmsg *, struct ptrace_args *);
```

The ptrace system call allows one process to control another:

**Operations:**
- `PT_TRACE_ME` - Mark process as traceable
- `PT_ATTACH` - Attach to process as debugger
- `PT_DETACH` - Detach from traced process
- `PT_CONTINUE` - Resume execution
- `PT_STEP` - Single-step execution
- `PT_READ_I/PT_WRITE_I` - Read/write instruction space
- `PT_READ_D/PT_WRITE_D` - Read/write data space
- `PT_GETREGS/PT_SETREGS` - Read/write registers

**Security restrictions:**
- Cannot trace processes with P_SUGID flag (setuid/setgid)
- Cannot trace processes owned by other users (unless root)
- Traced process stops on signals for debugger examination

Debuggers (gdb, lldb) use ptrace to:
- Set breakpoints (write INT3 instruction)
- Read/modify memory and registers
- Single-step through code
- Examine process state after crashes

## Resource Limits

Each process has resource limits inherited from parent:

```c
struct proc {
    struct plimit *p_limit;  // Resource limits
    struct pstats *p_stats;  // Statistics and timers
    // ...
};

struct plimit {
    struct rlimit pl_rlimit[RLIM_NLIMITS];
};

struct rlimit {
    rlim_t rlim_cur;  // Current (soft) limit
    rlim_t rlim_max;  // Maximum (hard) limit
};
```

**Standard limits:**
- `RLIMIT_CPU` - CPU time (seconds)
- `RLIMIT_FSIZE` - Maximum file size
- `RLIMIT_DATA` - Data segment size
- `RLIMIT_STACK` - Stack size
- `RLIMIT_CORE` - Core file size
- `RLIMIT_RSS` - Resident set size
- `RLIMIT_MEMLOCK` - Locked memory
- `RLIMIT_NPROC` - Number of processes per uid
- `RLIMIT_NOFILE` - Number of open files
- `RLIMIT_SBSIZE` - Socket buffer size

Exceeded soft limits typically cause signals (SIGXCPU, SIGXFSZ). Hard limits cannot be exceeded.

## Process Accounting

### Resource Usage

```c
struct rusage {
    struct timeval ru_utime;   // User CPU time
    struct timeval ru_stime;   // System CPU time
    long ru_maxrss;            // Max resident set size
    long ru_ixrss;             // Shared memory size
    long ru_idrss;             // Unshared data size
    long ru_isrss;             // Unshared stack size
    long ru_minflt;            // Page faults (no I/O)
    long ru_majflt;            // Page faults (I/O)
    long ru_nswap;             // Swaps
    long ru_inblock;           // Block input operations
    long ru_oublock;           // Block output operations
    long ru_msgsnd;            // Messages sent
    long ru_msgrcv;            // Messages received
    long ru_nsignals;          // Signals received
    long ru_nvcsw;             // Voluntary context switches
    long ru_nivcsw;            // Involuntary context switches
};
```

Accumulated statistics are returned to parent via wait4() and can be queried via getrusage().

### Time Accounting

Processes track time in multiple ways:

```c
struct pstats {
    struct timeval p_start;    // Process start time
    struct rusage p_ru;        // Self resource usage
    struct rusage p_cru;       // Cumulative child usage
};
```

**Time types:**
- **Real time** - Wall clock time since start
- **User time** - CPU time in user mode
- **System time** - CPU time in kernel mode

Tracked per-process and accumulated across all children.

## Summary

Process and thread management in DragonFly BSD implements a three-level model:

1. **Processes** provide resource containers with credentials, address spaces, and file descriptors
2. **LWPs** provide user-visible threads within processes
3. **LWKT threads** provide the low-level scheduling primitive

The lifecycle follows:
- **Creation** via fork1() with two-phase LWP initialization around vm_fork()
- **Execution** via kern_execve() with image activators and point-of-no-return design
- **Termination** via exit1() with comprehensive cleanup and zombie transition
- **Reaping** via kern_wait() with waitgen optimization and zombie cleanup

Key design features:
- PID anti-reuse protection via pid_doms[] array
- Reference counting with PHOLD/PRELE and zombie-specific PHOLDZOMB/PRELEZOMB
- P_WEXIT coordination to prevent concurrent exit
- Two-phase LWP creation to hide partially-initialized state
- P_INEXEC flag to serialize exec in multi-threaded processes
- Waitgen optimization to avoid spurious wakeups in wait()
- Reaper hierarchy for flexible orphan handling

All code locations follow the `~/s/dragonfly/sys/kern/` directory structure as documented.
