# Signals

**Source file:** `kern_sig.c` (2,701 lines)

This document covers signal management in DragonFly BSD, including signal generation, delivery, and handling. Signals are asynchronous notifications delivered to processes or threads to indicate events such as exceptions, terminal I/O, process control, or user-defined events.

---

## Overview

DragonFly BSD implements POSIX and BSD signal semantics with extensions for:

1. **Per-thread and per-process signals** — Signals can target specific LWPs or the process generally
2. **Signal masking** — Per-thread signal masks control delivery
3. **Signal actions** — Processes can catch, ignore, or use default handling
4. **Process control signals** — STOP/CONT signals for job control
5. **Core dumps** — SA_CORE signals generate core files
6. **Real-time signals** — Extended signal numbers beyond traditional POSIX
7. **Cross-CPU delivery** — IPI-based notification for signals to remote CPUs

**Key data structures:**
- `struct sigacts` — Per-process signal actions and state
- `sigset_t` — Bit set representing signals (32+ signals)
- `p->p_siglist` — Process-wide pending signals
- `lp->lwp_siglist` — Thread-specific pending signals
- `lp->lwp_sigmask` — Per-thread signal mask

---

## Signal Properties

### Signal Categories

Source: `kern_sig.c:119-194`

Each signal has properties encoded in `sigproptbl[]`:

- **SA_KILL** (`0x01`) — Terminates process by default
- **SA_CORE** (`0x02`) — Terminates and generates core dump
- **SA_STOP** (`0x04`) — Stops process execution
- **SA_TTYSTOP** (`0x08`) — Stop from terminal (SIGTSTP/SIGTTIN/SIGTTOU)
- **SA_IGNORE** (`0x10`) — Ignored by default
- **SA_CONT** (`0x20`) — Continues stopped process
- **SA_CANTMASK** (`0x40`) — Cannot be blocked (SIGKILL/SIGSTOP)
- **SA_CKPT** (`0x80`) — Checkpoint signal (DragonFly extension)

**Examples:**
- `SIGKILL` — SA_KILL (cannot be caught or ignored)
- `SIGSEGV` — SA_KILL | SA_CORE (core dump on segmentation fault)
- `SIGSTOP` — SA_STOP | SA_CANTMASK (cannot be blocked)
- `SIGCHLD` — SA_IGNORE (default is to ignore)
- `SIGCONT` — SA_IGNORE | SA_CONT (resumes stopped processes)

### Unmaskable Signals

Source: `kern_sig.c:196, 417`

`SIGKILL` and `SIGSTOP` cannot be masked, caught, or ignored:

```c
sigset_t sigcantmask_mask;  // Contains SIGKILL and SIGSTOP
SIG_CANTMASK(mask);         // Macro removes unmaskable signals
```

This ensures that processes can always be killed or stopped by administrators.

---

## Data Structures

### `struct sigacts` — Per-Process Signal Actions

Source: `sys/signalvar.h:56-73`

```c
struct sigacts {
    sig_t ps_sigact[_SIG_MAXSIG];      /* Signal handlers */
    sigset_t ps_catchmask[_SIG_MAXSIG]; /* Masks during handler */
    struct {
        int pid;  /* Originating process PID */
        int uid;  /* Originating process UID */
    } ps_frominfo[_SIG_MAXSIG];
    
    sigset_t ps_sigignore;    /* Signals set to SIG_IGN */
    sigset_t ps_sigcatch;     /* Signals with custom handlers */
    sigset_t ps_sigonstack;   /* Use alternate signal stack */
    sigset_t ps_sigintr;      /* Interrupt syscalls (no SA_RESTART) */
    sigset_t ps_sigreset;     /* Reset to SIG_DFL after catching (SA_RESETHAND) */
    sigset_t ps_signodefer;   /* Don't mask signal during handler (SA_NODEFER) */
    sigset_t ps_siginfo;      /* Use siginfo_t (SA_SIGINFO) */
    
    unsigned int ps_refcnt;
    int ps_flag;              /* PS_NOCLDSTOP, PS_NOCLDWAIT, PS_CLDSIGIGN */
};
```

**Key fields:**
- `ps_sigact[]` — Array of signal handlers (SIG_DFL, SIG_IGN, or function pointer)
- `ps_catchmask[]` — Signals to block while handler executes
- `ps_frominfo[]` — Tracks sender's PID/UID for signal provenance

**Flags:**
- `PS_NOCLDSTOP` — Don't notify parent of child stop/cont (SA_NOCLDSTOP)
- `PS_NOCLDWAIT` — Don't create zombies, reap immediately (SA_NOCLDWAIT)
- `PS_CLDSIGIGN` — SIGCHLD handler is SIG_IGN

### Signal Masks (`sigset_t`)

Source: `sys/signalvar.h:91-150`

Bit set representing 32+ signals:

```c
typedef struct {
    unsigned int __bits[_SIG_WORDS];  /* _SIG_WORDS = 4 for 128 signals */
} sigset_t;
```

**Operations (macros):**
- `SIGADDSET(set, sig)` — Add signal to set
- `SIGDELSET(set, sig)` — Remove signal from set
- `SIGISMEMBER(set, sig)` — Test membership
- `SIGEMPTYSET(set)` — Clear all signals
- `SIGFILLSET(set)` — Set all signals
- `SIGSETOR(set1, set2)` — Union of sets
- `SIGSETNAND(set1, set2)` — Remove set2 from set1

**Atomic variants:**
- `SIGADDSET_ATOMIC(set, sig)` — Uses `atomic_set_int()` for SMP safety
- `SIGDELSET_ATOMIC(set, sig)` — Uses `atomic_clear_int()`

**Process vs. Thread signals:**
- `p->p_siglist` — Process-wide pending signals (any thread can handle)
- `lp->lwp_siglist` — Thread-specific pending signals (only this LWP handles)
- `lp->lwp_sigmask` — Per-thread signal mask

---

## Signal Actions (`sigaction`)

### Setting Signal Handlers

#### `kern_sigaction`

Source: `kern_sig.c:248-377`

Set signal disposition (handler, mask, flags):

```c
int kern_sigaction(int sig, struct sigaction *act, struct sigaction *oact);
```

**Validation:**
1. Check signal number (`1 <= sig < _SIG_MAXSIG`)
2. Reject attempts to catch `SIGKILL` or `SIGSTOP`
3. Acquire `p->p_token` for atomicity

**Installation:**
1. Update `ps->ps_sigact[sig]` with handler
2. Update `ps->ps_catchmask[sig]` with additional mask
3. Set flags in various `ps_sig*` masks:
   - `SA_ONSTACK` → `ps_sigonstack`
   - `SA_RESTART` → clear `ps_sigintr`
   - `SA_RESETHAND` → `ps_sigreset`
   - `SA_NODEFER` → `ps_signodefer`
   - `SA_SIGINFO` → `ps_siginfo`
4. Handle `SIGCHLD` special flags (SA_NOCLDSTOP, SA_NOCLDWAIT)

**Signal state updates:**
- If action is `SIG_IGN` or default-ignore → remove from pending signals
- Update `p_sigignore` and `p_sigcatch` sets accordingly
- Iterate all LWPs to clear pending instances

**PID 1 restriction:** Process 1 (init) cannot set SA_NOCLDWAIT to prevent zombie accumulation.

### Signal Initialization

#### `siginit` — Process 0 Setup

Source: `kern_sig.c:404-418`

Called during kernel bootstrap:

1. Initialize `p_sigignore` with default-ignored signals
2. Set global `sigcantmask_mask` (SIGKILL + SIGSTOP)

#### `execsigs` — Reset on Exec

Source: `kern_sig.c:423-464`

Called by `execve()` to reset signal state:

1. Reset all caught signals to SIG_DFL
2. Clear signal stack (reset to user stack)
3. Clear SA_NOCLDWAIT and SA_NOCLDSTOP flags
4. Reset SIGCHLD to SIG_DFL if ignored

**Rationale:** Exec'd program starts with clean signal state (caught signals don't persist across exec).

---

## Signal Masking

### `kern_sigprocmask`

Source: `kern_sig.c:472-509`

Modify thread's signal mask:

```c
int kern_sigprocmask(int how, sigset_t *set, sigset_t *oset);
```

**Operations:**
- `SIG_BLOCK` — Add signals to mask: `lwp_sigmask |= *set`
- `SIG_UNBLOCK` — Remove signals from mask: `lwp_sigmask &= ~*set`
- `SIG_SETMASK` — Replace mask: `lwp_sigmask = *set`

**Unmaskable enforcement:** `SIG_CANTMASK()` macro always removes SIGKILL/SIGSTOP.

**Interlock:** After `SIG_SETMASK`, calls `sigirefs_wait()` to synchronize with concurrent signal delivery (prevents races with `sigsuspend()`/`ppoll()`/`pselect()`).

### `kern_sigpending`

Source: `kern_sig.c:541-548`

Return set of pending signals:

```c
int kern_sigpending(sigset_t *set);
```

Returns union of process and thread pending signals:

```c
*set = lwp_sigpend(lp);  // p->p_siglist | lp->lwp_siglist
```

### `kern_sigsuspend`

Source: `kern_sig.c:573-604`

Atomically change mask and sleep until signal:

```c
int kern_sigsuspend(sigset_t *set);
```

**Algorithm:**
1. Save old mask in `lp->lwp_oldsigmask`
2. Set `LWP_OLDMASK` flag (indicates sigsuspend in progress)
3. Acquire `lp->lwp_token` (interlocks signal delivery)
4. Set temporary mask: `lp->lwp_sigmask = *set`
5. Release token and call `sigirefs_wait()` to synchronize
6. Sleep in `tsleep(ps, PCATCH, "pause", 0)`
7. Wake on signal delivery, mask restored in `postsig()`

**Interlock:** Holding `lp->lwp_token` during mask change ensures signal delivery sees consistent state.

---

## Signal Generation

### `kern_kill` — Send Signal to Process/Thread

Source: `kern_sig.c:748-857`

Entry point for `kill()` and `lwp_kill()` system calls:

```c
int kern_kill(int sig, pid_t pid, lwpt_t tid);
```

**Target selection:**
- `pid > 0, tid == -1` — Signal process (any thread)
- `pid > 0, tid >= 0` — Signal specific thread
- `pid == 0` — Signal own process group
- `pid == -1` — Broadcast to all processes (privileged)
- `pid < -1` — Signal process group `-pid`

**Permission check:**
- `CANSIGIO()` macro: root or matching UID
- `p_trespass()` for cross-process signals

**Delivery:**
- Calls `lwpsignal(p, lp, sig)` with target process/thread

### `ksignal` and `lwpsignal` — Core Signal Delivery

Source: `kern_sig.c:1115-1459`

The heart of signal delivery:

```c
void ksignal(struct proc *p, int sig);              // Generic process signal
void lwpsignal(struct proc *p, struct lwp *lp, int sig); // Specific or auto-select LWP
```

**Target selection** (if `lp == NULL`):
1. Check if current preempted thread belongs to `p` and doesn't mask signal
2. Otherwise call `find_lwp_for_signal()`:
   - Prefer LSRUN (running) threads
   - Then LSSLEEP (sleeping with LWP_SINTR)
   - Finally LSSTOP (stopped) threads
3. Returns LWP with token held, or NULL if all threads mask signal

**Signal processing:**

1. **Ignored signals:**
   - If `SIGISMEMBER(p_sigignore, sig)` → discard (unless P_TRACED)
   - Still notify kqueue: `KNOTE(&p->p_klist, NOTE_SIGNAL | sig)`

2. **Continue signals (SA_CONT):**
   - Clear all pending STOP signals: `SIG_STOPSIGMASK_ATOMIC(p->p_siglist)`
   - If process stopped → call `proc_unstop()` → wake all threads

3. **Stop signals (SA_STOP):**
   - Clear all pending CONT signals: `SIG_CONTSIGMASK_ATOMIC(p->p_siglist)`
   - TTY stop signals ignored if orphaned process group
   - If default action → call `proc_stop()` to stop process

4. **Process stopped (p->p_stat == SSTOP):**
   - Add signal to pending list but don't wake (unless SIGKILL or SIGCONT)
   - SIGKILL → call `proc_unstop()` to make runnable
   - SIGCONT → continue process and optionally notify parent

5. **Active process:**
   - Find suitable LWP (if not already specified)
   - Add signal to `lp->lwp_siglist` (thread-specific)
   - Call `lwp_signotify(lp)` to wake/interrupt thread

### `lwp_signotify` — Wake Thread for Signal

Source: `kern_sig.c:1482-1548`

Notify LWP that signal has arrived:

**Cases:**
1. **Preempted on current CPU:**
   - Call `signotify()` (sets TDF_SIGPENDING, will check on return to userland)

2. **Sleeping with LWP_SINTR:**
   - Thread in `tsleep()` with `PCATCH` flag
   - If local CPU → call `setrunnable(lp)`
   - If remote CPU → send IPI via `lwkt_send_ipiq()`

3. **Sleeping with TDF_SINTR:**
   - Thread in `lwkt_sleep()` with `PCATCH`
   - Same local/remote logic as above

4. **Running in userland:**
   - Send IPI to remote CPU to knock thread into kernel
   - IPI handler (`lwp_signotify_remote`) calls `signotify()`

**IPI handling:** IPIs forward `LWPHOLD()` reference to target CPU if thread migrates.

### `find_lwp_for_signal`

Source: `kern_sig.c:996-1095`

Select best LWP to receive signal:

**Priority:**
1. **Current preempted thread** (if doesn't mask signal) — avoids context switch
2. **LSRUN thread** — already running, will return to userland soon
3. **LSSLEEP thread with LWP_SINTR** — can be interrupted
4. **LSSTOP thread** — stopped, will check signal when resumed

**Locking:** Returns LWP with `lwp_token` held and `LWPHOLD()` reference.

---

## Signal Delivery Path

### Process Control Signals

#### `proc_stop` — Stop All Threads

Source: `kern_sig.c:1584-1660`

Called when stop signal arrives (default action):

```c
void proc_stop(struct proc *p, int stat);  // stat = SSTOP or SCORE
```

**Algorithm:**
1. Set `p->p_stat = SSTOP` (or SCORE for coredump)
2. For each LWP:
   - **LSSTOP:** Already stopped, no action
   - **LSSLEEP:** Set `LWP_MP_WSTOP`, increment `p->p_nstopped`
   - **LSRUN:** Call `lwp_signotify()` to interrupt
3. If all threads stopped (`p->p_nstopped == p->p_nthreads`):
   - Clear `P_WAITED` flag
   - Wake parent: `wakeup(parent)`
   - Send `SIGCHLD` (unless PS_NOCLDSTOP set)

**SCORE state:** Special state for coredump — cannot be overridden by SIGCONT until coredump completes.

**LWP_MP_WSTOP flag:** Prevents sleeping threads from incrementing `p->p_nstopped` again when they reach `tstop()`.

#### `proc_unstop` — Resume All Threads

Source: `kern_sig.c:1666-1728`

Called when SIGCONT arrives or SIGKILL overrides stop:

```c
void proc_unstop(struct proc *p, int stat);
```

**Algorithm:**
1. Verify `p->p_stat == stat` (SSTOP or SCORE)
2. Set `p->p_stat = SACTIVE`
3. For each LWP:
   - **LSRUN:** Already running (unexpected but allowed)
   - **LSSLEEP:** Clear `LWP_MP_WSTOP`, call `setrunnable()`
   - **LSSTOP:** Call `setrunnable()` to wake thread

**Effect:** All threads transition from stopped to runnable, will return to userland or continue execution.

#### `proc_stopwait` — Wait for All Threads to Stop

Source: `kern_sig.c:1731-1748`

Used before coredump to ensure all threads fully stopped:

```c
while (p->p_nstopped < p->p_nthreads) {
    tsleep(&p->p_nstopped, 0, "stopwait", 1);
}
```

Polls until `p->p_nstopped` reaches `p->p_nthreads`.

---

## Signal Dispatch

### `issignal` — Check for Pending Signal

Source: `kern_sig.c:1979-2248`

Called via `CURSIG()` macro to check if signal should be delivered:

```c
int issignal(struct lwp *lp, int maytrace, int *ptokp);
```

**Returns:** Signal number to handle, or 0 if none.

**Algorithm:**

1. **Quick check without token:**
   - Compute `mask = lwp_sigpend(lp) & ~lwp_sigmask`
   - Remove stop signals if `P_PPWAIT` (vfork parent)
   - If empty → return 0 (no signal)

2. **Acquire token if signal in process list:**
   - Recheck mask with token held (double-check pattern)

3. **Handle ignored signals:**
   - If `SIGISMEMBER(p_sigignore, sig)` → delete and continue

4. **Tracing (P_TRACED):**
   - Stop process: `proc_stop(p, SSTOP)`
   - Call `tstop()` to block thread
   - Parent can modify signal via ptrace: `p->p_xstat`
   - If parent clears signal → continue loop

5. **Determine action:**
   - `SIG_DFL` — Default action (check properties)
   - `SIG_IGN` — Ignored (shouldn't happen, but continue)
   - Custom handler — return signal number

6. **Default action handling:**
   - **SA_CKPT:** Call `checkpoint_signal_handler()` (DragonFly checkpoint)
   - **SA_STOP:** Call `proc_stop()`, delete signal, continue loop
   - **SA_IGNORE:** Delete signal, continue loop (e.g., SIGCONT)
   - **SA_KILL/SA_CORE:** Return signal for `postsig()` to handle

7. **Delete signal from pending lists:**
   - `lwp_delsig(lp, sig, haveptok)` removes from both `p_siglist` and `lwp_siglist`

**Token management:** Carefully tracks whether `p->p_token` is held via `haveptok` flag, returns ownership via `ptokp` pointer.

### `postsig` — Execute Signal Action

Source: `kern_sig.c:2260-2360`

Deliver signal to handler or terminate process:

```c
void postsig(int sig, int haveptok);
```

**Called from:** Trap handler or syscall return path (userret).

**Actions:**

1. **Virtual kernel:** If in vkernel context, switch back to kernel context

2. **Delete signal:** `lwp_delsig(lp, sig, haveptok)`

3. **Notify kqueue:** `KNOTE(&p->p_klist, NOTE_SIGNAL | sig)`

4. **Default action (SIG_DFL):**
   - Call `sigexit(lp, sig)` to terminate process
   - Generates core dump if SA_CORE property
   - Does not return

5. **Custom handler:**
   - Determine mask to restore after handler:
     - If `LWP_OLDMASK` set (from sigsuspend) → use `lwp_oldsigmask`
     - Otherwise → use current `lwp_sigmask`
   - Block additional signals: `SIGSETOR(lwp_sigmask, ps_catchmask[sig])`
   - Unless SA_NODEFER → also block signal itself
   - Reset handler to SIG_DFL if SA_RESETHAND
   - Call platform-specific sendsig: `(*sv_sendsig)(action, sig, &returnmask, code)`
   - Increment `ru_nsignals` counter

**Machine-dependent sendsig:**
- Sets up signal trampoline on user stack
- Modifies user registers to call handler
- Stores return mask for `sigreturn()` syscall

---

## Special Signal Handling

### `trapsignal` — Synchronous Signal from Trap

Source: `kern_sig.c:940-985`

Deliver signal caused by trap (e.g., SIGSEGV, SIGFPE):

```c
void trapsignal(struct lwp *lp, int sig, u_long code);
```

**Difference from regular signals:** These signals MUST be delivered to the specific LWP that caused the trap (never delivered generically to process).

**Fast path:** If signal is caught and not masked:
- Immediately call `(*sv_sendsig)()` to invoke handler
- No need to make signal pending
- Update signal mask and apply SA_RESETHAND/SA_NODEFER

**Slow path:** Otherwise call `lwpsignal(p, lp, sig)` to queue signal.

**Virtual kernel:** If in vkernel emulation, switch back to vkernel context before delivering.

### `sigexit` — Terminate with Signal

Source: `kern_sig.c:2384-2430`

Force process exit due to signal:

```c
void sigexit(struct lwp *lp, int sig);
```

**Steps:**

1. Set `p->p_acflag |= AXSIG` (accounting: terminated by signal)

2. **Core dump (SA_CORE signals):**
   - Stop all threads: `proc_stop(p, SCORE)` + `proc_stopwait(p)`
   - Call `coredump(lp, sig)` to write core file
   - If successful → set `WCOREFLAG` in exit status
   - Log message: `"pid %d (%s), uid %d: exited on signal %d (core dumped)"`

3. **Exit:** Call `exit1(W_EXITCODE(0, sig))` — does not return

**Sysctl:** `kern.logsigexit` controls logging (default 1).

### `coredump` — Generate Core File

Source: `kern_sig.c:2515-2678`

Write core dump to filesystem:

```c
static int coredump(struct lwp *lp, int sig);
```

**Algorithm:**

1. **Check permissions:**
   - If sugid process → check `kern.sugid_coredump` sysctl
   - If disabled globally → check `kern.coredump` sysctl

2. **Expand core filename:**
   - Default: `"%N.core"` (process name + ".core")
   - Supports format specifiers: `%N` (name), `%P` (pid), `%U` (uid)
   - Example: `"/cores/%U/%N-%P"` → `/cores/1000/myapp-1234`

3. **Create core file:**
   - Call `nlookup_init_at()` with expanded path
   - Open with `O_CREAT | O_TRUNC | O_NOFOLLOW`
   - Prevent following symlinks (security)

4. **Write core:**
   - Call `(*p->p_sysent->sv_coredump)(lp, sig, vp, limit)`
   - Platform-specific function writes ELF core format
   - Includes registers, memory segments, thread info

5. **Cleanup:**
   - Close file
   - Release vnode

**Security:** Setuid/setgid programs don't dump core by default (prevents password/key leakage).

---

## Process Group Signals

### `pgsignal` — Signal Process Group

Source: `kern_sig.c:911-929`

Send signal to all members of process group:

```c
void pgsignal(struct pgrp *pgrp, int sig, int checkctty);
```

**Parameters:**
- `pgrp` — Process group structure
- `sig` — Signal number
- `checkctty` — If 1, only signal processes with controlling terminal

**Algorithm:**
1. Acquire `pgrp->pg_lock` (prevents concurrent fork from missing signal)
2. Iterate `pgrp->pg_members` list
3. For each process:
   - If `checkctty == 0` or `p->p_flags & P_CONTROLT` → call `ksignal(p, sig)`

**Locking:** Process group lock ensures that processes forking during signal delivery either:
- See the lock and wait → receive signal after fork completes
- Complete fork before lock → child added to group and receives signal

---

## Wait for Signal

### `kern_sigtimedwait` — Wait for Specific Signals

Source: `kern_sig.c:1754-1866`

Wait for signal from specified set (with optional timeout):

```c
static int kern_sigtimedwait(sigset_t waitset, siginfo_t *info,
                               struct timespec *timeout);
```

**Used by:** `sigwaitinfo()`, `sigtimedwait()` system calls.

**Algorithm:**

1. Save current signal mask
2. Compute timeout deadline (if specified)
3. Loop:
   - Check if any signal in `waitset` is pending: `set = lwp_sigpend(lp) & waitset`
   - If signal found:
     - Temporarily fill signal mask to block all signals
     - Call `issignal(lp, 1, NULL)` to process signal
     - If SIGSTOP → may return 0, retry
     - Delete signal from pending list
     - Return signal number
   - If no signal and timeout expired → return EAGAIN
   - Otherwise:
     - Block all signals in `waitset`: `lwp_sigmask &= ~waitset`
     - Call `sigirefs_wait()` to synchronize
     - Sleep: `tsleep(&p->p_sigacts, PCATCH, "sigwt", hz)`
     - Wake on signal delivery (broken by `lwpsignal()`)
     - Retry loop

4. Restore original signal mask

**Return:** Signal number in `info->si_signo`, or error code.

**Note:** Signal is **consumed** (removed from pending list), unlike normal signal delivery which queues for handler.

---

## Kqueue Integration

### `filt_sigattach`/`filt_signal`

Source: `kern_sig.c:84-89, 2562-2614`

Kqueue filter for signal notification:

```c
struct filterops sig_filtops = {
    FILTEROP_MPSAFE,
    filt_sigattach,
    filt_sigdetach,
    filt_signal
};
```

**Attach:** Register knote on process: `KNOTE_INSERT(&p->p_klist, kn)`

**Signal:** When signal arrives, `lwpsignal()` calls:
```c
KNOTE(&p->p_klist, NOTE_SIGNAL | sig);
```

This wakes any threads waiting in `kevent()` for signal notification.

**Use case:** Alternative to `sigwait()` — allows waiting for signals via kqueue instead of signal-specific APIs.

---

## Signal Interlock Mechanism

### `sigirefs` — Signal Delivery Interlock

Source: (referenced throughout `kern_sig.c`)

Prevents races between signal delivery and operations that change the signal mask (sigsuspend, ppoll, pselect):

```c
void sigirefs_hold(struct proc *p);     // Increment p->p_sigirefs
void sigirefs_drop(struct proc *p);     // Decrement p->p_sigirefs
void sigirefs_wait(struct proc *p);     // Wait for p->p_sigirefs == 0
```

**Problem:** Without interlock:
1. Thread calls `sigsuspend()`, changes mask, about to sleep
2. Signal arrives, sees old mask, delivered to process list instead of LWP
3. Thread sleeps, signal not delivered to correct LWP

**Solution:**
1. `sigsuspend()` calls `sigirefs_wait()` before sleeping → waits for pending signal delivery to complete
2. `lwpsignal()` calls `sigirefs_hold()` before checking mask → prevents mask changes during delivery
3. After delivery, `sigirefs_drop()` releases hold

This ensures mask changes and signal delivery don't race.

---

## Syscall Signal Interruption

### `iscaught` — Check for Interrupting Signal

Source: `kern_sig.c:1948-1962`

Check if system call should be interrupted:

```c
int iscaught(struct lwp *lp);
```

**Returns:**
- `EINTR` — Signal interrupts syscall (signal in `ps_sigintr`)
- `ERESTART` — Syscall should be restarted (signal not in `ps_sigintr`, i.e., SA_RESTART)
- `EWOULDBLOCK` — No signal pending

**Used by:** Long-running syscalls (read, write, sleep) to check for pending signals.

**Flow:**
1. Call `CURSIG(lp)` → `issignal()`
2. If signal found → check if in `ps_sigintr` set
3. Return appropriate error code
4. Syscall code checks error and either aborts or restarts

---

## DragonFly-Specific Extensions

### Checkpoint Signals

Source: `kern_sig.c:162-163`

DragonFly provides checkpoint/resume functionality via signals:

- **SIGCKPT** (`32`) — SA_CKPT property, triggers `checkpoint_signal_handler()`
- **SIGCKPTEXIT** (`33`) — SA_CKPT | SA_KILL, checkpoint and exit

**Use case:** Save process state to disk, allowing resume later or on different machine.

### Cross-CPU Signal Delivery

DragonFly's LWKT threading and per-CPU design requires IPI-based signal notification:

- `lwp_signotify()` checks if target LWP is on remote CPU
- Sends IPI via `lwkt_send_ipiq(gd, lwp_signotify_remote, lp)`
- Remote CPU calls `signotify()` or `lwkt_schedule()` to wake thread

**Forwarding:** If thread migrates to another CPU before IPI delivery, IPI is forwarded again (with LWPHOLD reference).

### Thread-Specific Signals

`lwp_kill()` syscall allows targeting specific thread (LWP):

```c
int lwp_kill(pid_t pid, lwpt_t tid, int sig);
```

**Restriction:** `tid` cannot be -1 (use `kill()` for process signals).

**Use case:** Send signal to specific thread in multi-threaded process (e.g., sampling profiler).

---

## Interaction with Other Subsystems

### Signal and Fork

Source: `kern_fork.c`

On `fork()`:
1. Child inherits `p_sigacts` (shared, refcounted)
2. Child's `p_siglist` cleared (no pending signals)
3. Child's `lp->lwp_siglist` cleared
4. Child's `lp->lwp_sigmask` inherited from parent

On `rfork(RFPROC)`:
- Same as fork

On `rfork(RFTHREAD)`:
- `p_sigacts` shared with parent
- `lwp_sigmask` inherited
- Signals can target specific thread

### Signal and Exec

Source: `kern_exec.c`, calls `execsigs()`

On `execve()`:
1. Reset all caught signals to SIG_DFL
2. Held signals remain held (preserved in `lwp_sigmask`)
3. Reset signal stack to user stack
4. Clear SA_NOCLDWAIT / SA_NOCLDSTOP
5. Reset SIGCHLD to SIG_DFL if ignored

**Rationale:** New program image shouldn't inherit old program's signal handlers.

### Signal and Exit

Source: `kern_exit.c`

On `exit()`:
1. Parent receives SIGCHLD (unless PS_NOCLDSTOP or process stopped)
2. If SA_NOCLDWAIT set → child immediately reaped (no zombie)
3. Otherwise → child becomes zombie, `wait()` retrieves exit status
4. If signal caused exit → `p->p_xstat` contains signal number | WCOREFLAG

### Signal and Ptrace

Source: `kern_sig.c:2060-2130`

When process traced (P_TRACED):
1. `issignal()` stops process on every signal
2. Parent debugger notified
3. Debugger can:
   - Inspect signal number in `p->p_xstat`
   - Modify signal (change `p->p_xstat`)
   - Clear signal (set `p->p_xstat = 0`)
   - Continue process with `PTRACE_CONT`

**Use case:** Debuggers intercept signals for single-stepping, breakpoints, etc.

---

## Key Algorithms

### Signal Delivery Decision Tree

```
lwpsignal(p, lp, sig):
    1. Is signal ignored (p_sigignore)?
       → Yes: Discard (notify kqueue)
       → No: Continue

    2. Is signal a CONT (SA_CONT)?
       → Yes: Clear pending STOP signals
       → If process stopped: unstop process
       → Continue

    3. Is signal a STOP (SA_STOP)?
       → Yes: Clear pending CONT signals
       → If default action: stop process, done
       → Otherwise: Continue

    4. Is process already stopped (SSTOP)?
       → Yes: Add signal to pending list
       → If SIGKILL: unstop process
       → If SIGCONT and caught: unstop process
       → Otherwise: done

    5. Find target LWP:
       → If lp == NULL: find_lwp_for_signal()
       → If all LWPs mask signal: deliver to process

    6. Add signal to lwp_siglist
    7. Call lwp_signotify(lp) to wake thread
```

### Signal Dispatch Loop

```
User process trap/syscall return:
    while (sig = CURSIG(lp)):
        postsig(sig):
            if action == SIG_DFL:
                sigexit(lp, sig)  // Does not return
            else:
                Setup signal trampoline
                Call (*sv_sendsig)(action, sig, &mask, code)
                Return to userland at handler
```

Handler executes, calls `sigreturn()`, kernel restores original mask and PC, returns to interrupted code.

---

## Performance Considerations

### Signal Mask Operations

Signal masks use 128-bit sets (_SIG_WORDS = 4), operations are:
- `SIGADDSET` / `SIGDELSET` — O(1) bit operations
- `SIGEMPTYSET` / `SIGFILLSET` — O(_SIG_WORDS) loop (4 iterations)
- `SIGSETOR` / `SIGSETNAND` — O(_SIG_WORDS) loop

**Optimization:** Atomic variants avoid lock overhead in `p->p_siglist`:
- `SIGADDSET_ATOMIC` — `atomic_set_int()`
- `SIGDELSET_ATOMIC` — `atomic_clear_int()`

### Signal Delivery Fast Path

`issignal()` has fast path without token:
```c
mask = lwp_sigpend(lp);
SIGSETNAND(mask, lp->lwp_sigmask);
if (SIGISEMPTY(mask))
    return (0);  // No signal, no token acquired
```

Only acquires `p->p_token` if signal found in process list.

### Cross-CPU Delivery

`lwp_signotify()` checks if target LWP is local before sending IPI:
```c
if (dtd->td_gd == mycpu) {
    setrunnable(lp);  // Local, no IPI
} else {
    lwkt_send_ipiq(dtd->td_gd, lwp_signotify_remote, lp);  // Remote IPI
}
```

Avoids IPI overhead for same-CPU signals.

---

## Debugging and Observability

### Signal Logging

**Sysctl:**
- `kern.logsigexit` — Log signal-caused exits (default 1)
- `kern.coredump` — Enable/disable core dumps (default 1)
- `kern.sugid_coredump` — Allow setuid/setgid core dumps (default 0)

**Ktrace:**
- `KTR_PSIG` — Trace signal delivery via `ktrace()`
- Logs: signal number, action, mask, code

**Log format:**
```
pid %d (%s), uid %d: exited on signal %d (core dumped)
```

### Kqueue Monitoring

Register kevent to monitor process signals:
```c
struct kevent kev;
EV_SET(&kev, pid, EVFILT_PROC, EV_ADD, NOTE_SIGNAL, 0, NULL);
kevent(kq, &kev, 1, NULL, 0, NULL);
```

Wakes when any signal delivered to process.

---

## Summary

DragonFly BSD's signal implementation provides:

1. **POSIX compliance** with extensions for per-thread signals and checkpointing
2. **Efficient signal delivery** with fast-path checks and cross-CPU IPI notification
3. **Fine-grained control** via SA_* flags (RESTART, RESETHAND, NODEFER, SIGINFO)
4. **Process control** via STOP/CONT signals with accurate thread stopping
5. **Ptrace integration** for debugging with signal interception
6. **Core dump generation** with configurable paths and security controls
7. **Kqueue integration** for event-based signal monitoring

Key design principles:

- **Per-thread masks** allow fine-grained control in multi-threaded processes
- **Copy-on-write sigacts** optimize fork() performance
- **Token-based locking** ensures atomicity without global signal lock
- **IPI-based notification** supports per-CPU LWKT threading model
- **Double-check pattern** optimizes fast path (check without lock, recheck with lock)
- **Signal interlock** (`sigirefs`) prevents races with mask-changing operations

The signal subsystem forms the foundation for:
- **Job control** (shell background/foreground)
- **Process monitoring** (parent notification of child events)
- **Exception handling** (trap delivery to user handlers)
- **Debugging** (ptrace signal interception)
- **Inter-process communication** (asynchronous event notification)
