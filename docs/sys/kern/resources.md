# Process Resources and Credentials

**Source files:** `kern_descrip.c`, `kern_plimit.c`, `kern_resource.c`, `kern_prot.c`

This document covers the management of process resources, limits, credentials, and file descriptors in DragonFly BSD. These subsystems provide resource accounting, access control, and per-process resource tracking.

---

## Overview

Process resource management encompasses four major areas:

1. **File descriptors** (`kern_descrip.c`) — per-process file descriptor tables with thread-local caching
2. **Resource limits** (`kern_plimit.c`) — copy-on-write limit structures (RLIMIT_* values)
3. **Resource accounting** (`kern_resource.c`) — priority management, CPU usage tracking, per-user accounting
4. **Credentials** (`kern_prot.c`) — UID/GID management with atomic copy-on-write semantics

All four interact closely: file descriptors are subject to resource limits (RLIMIT_NOFILE), credentials control access to resources, and resource accounting tracks consumption per user and process.

---

## File Descriptors (`kern_descrip.c`)

### Data Structures

#### `struct filedesc`

The per-process file descriptor table:

```c
struct filedesc {
    struct file **fd_files;        /* File pointer array */
    uint32_t fd_cmask;             /* umask for open() */
    int fd_lastfile;               /* High water mark */
    int fd_freefile;               /* Hint for next free fd */
    int fd_nfiles;                 /* Total slots allocated */
    int fd_refcnt;                 /* Reference count */
    struct uidinfo *fd_uinfo;      /* Per-user accounting */
};
```

Key points:
- `fd_files[]` is dynamically resized as file descriptors are allocated
- Binary tree structure tracks free slots for efficient allocation
- Each process owns one `filedesc`, inherited from parent on fork()

#### Thread-local Caching (`td_fdcache`)

Each thread maintains a small cache to avoid expensive reference counting:

```c
struct thread {
    struct file *td_fdcache[NFDCACHE];  /* Cached file pointers */
    // NFDCACHE = 16
};
```

**Cache modes** (stored in low bits of pointer):
- **Mode 0:** Available slot, no reference held
- **Mode 1:** Locked (transitional state during lookup)
- **Mode 2:** Borrowed reference (can reuse without atomic inc/dec)

The cache dramatically improves performance for frequently used file descriptors (e.g., stdin/stdout/stderr).

### File Descriptor Allocation

#### Binary Tree Algorithm (`fdalloc_locked`)

Source: `kern_descrip.c:839-1064`

File descriptor slots are organized as a binary tree for O(log n) allocation:

```
         fd_freefile (hint)
              |
              v
    ┌─────────┴─────────┐
    │                   │
 left subtree      right subtree
```

**Key functions:**
- `right_subtree_size(fd, nfiles)` — size of right subtree at fd
- `right_ancestor(fd, nfiles)` — next right ancestor in tree
- `left_ancestor(fd, nfiles)` — next left ancestor in tree

**Allocation logic:**
1. Start at `fd_freefile` (last known free)
2. If slot free, allocate immediately
3. Otherwise, traverse tree using right_ancestor/left_ancestor
4. On failure, grow `fd_files[]` array

#### Growing the Descriptor Table

Source: `kern_descrip.c:1066-1227`

When the table is full:
1. Calculate new size: `nfiles + max(nfiles/8, 15) + 3`
2. Allocate new array (M_FILEDESC)
3. Copy old entries
4. Free old array
5. Update `fd_nfiles`

The growth strategy balances memory overhead with reallocation frequency.

### File Descriptor Operations

#### `fgetread`/`fgetwrite`/`fget`

Source: `kern_descrip.c:1492-1650`

Retrieve file pointer for descriptor `fd`:

1. **Check cache:** Look in `td_fdcache[]` first
2. **Fallback:** If not cached, search `fd_files[]`
3. **Validate:** Check bounds, NULL, and file type (read/write)
4. **Reference:** Increment `f_count` (borrowed ref avoids this)
5. **Cache:** Store in `td_fdcache[]` as mode 2 (borrowed)

**Borrowed references:** Cache entries hold refs without atomic ops, dramatically improving hot-path performance.

#### `fdrop` — Release File Reference

Source: `kern_descrip.c:2128-2217`

Decrement `f_count`; if zero, close file:

1. Atomic decrement of `f_count`
2. If non-zero, return
3. If zero:
   - Call `fo_close()` (file operations close)
   - Call `fdrevoke()` to invalidate all cached refs
   - Free file structure

**Locking:** Uses per-file `f_spin` spinlock for atomicity.

#### `dup`/`dup2`/`fcntl(F_DUPFD)`

Source: `kern_descrip.c:299-447`

Duplicate file descriptor:

- **`dup(old)`** — allocate lowest free fd, copy file pointer
- **`dup2(old, new)`** — force specific fd, close `new` if open
- **`fcntl(F_DUPFD, minfd)`** — allocate fd >= minfd

**Flags:**
- `DUP_FIXED` — dup2 behavior (specific fd)
- `DUP_VARIABLE` — dup behavior (any free fd)
- `DUP_CLOEXEC` — set close-on-exec flag

**Cache invalidation:** `fclearcache()` clears all thread caches when closing or revoking.

### File Descriptor Limits

Source: `kern_descrip.c:1229-1333`

Two limits apply:

1. **Per-process:** `RLIMIT_NOFILE` (default 1024, hard max 1,048,576)
2. **Per-user:** `maxfilesperuser` (default 80% of system max)

**Enforcement:**
- `fdalloc()` checks both limits before allocation
- `chgproccnt()` updates per-user `ui_proccnt` counter (via uidinfo)
- `chgopenfiles()` updates per-user `ui_openfiles` counter

**System-wide limit:** `maxfiles` (global sysctl, default computed from RAM).

### File Descriptor Revocation (`fdrevoke`)

Source: `kern_descrip.c:2219-2339`

Invalidate all references to a file:

1. Mark file with `FREVOKED` flag
2. Iterate all processes' file descriptor tables
3. For each match, set `FREVOKED` in `fd_files[]`
4. Call `fclearcache()` to purge thread caches
5. Wake sleeping threads (select/poll)

**Use case:** Device revocation (e.g., USB device unplugged).

---

## Resource Limits (`kern_plimit.c`)

### Data Structures

#### `struct plimit`

Process resource limits:

```c
struct plimit {
    struct rlimit pl_rlimit[RLIM_NLIMITS]; /* Limit array */
    int pl_refcnt;                          /* Reference count */
    uint32_t pl_flags;                      /* Flags */
};

#define PLIMITF_EXCLUSIVE  0x00000001  /* Private copy (multi-threaded) */
```

**Limit types** (subset of `RLIM_NLIMITS`):
- `RLIMIT_CPU` — CPU seconds (enforced in `kern_clock.c`)
- `RLIMIT_DATA` — Data segment size
- `RLIMIT_STACK` — Stack size
- `RLIMIT_CORE` — Core dump size
- `RLIMIT_NOFILE` — Open files per process
- `RLIMIT_VMEM` — Virtual memory
- `RLIMIT_NPROC` — Processes per user
- `RLIMIT_SBSIZE` — Socket buffer space per user

Each limit has soft (`rlim_cur`) and hard (`rlim_max`) values.

### Copy-on-Write Semantics

Source: `kern_plimit.c:105-212`

Process limits are shared across fork() using reference counting:

```
   parent fork → child
      ↓              ↓
   plimit ← pl_refcnt = 2
```

**`plimit_fork(struct plimit *olimit)`**

Called during fork():
1. If `PLIMITF_EXCLUSIVE` set → allocate private copy
2. Otherwise → increment `pl_refcnt`, share with child

**`plimit_lwp_fork(struct plimit *olimit)`**

Called when creating LWPs (multi-threaded process):
1. Always allocate private copy
2. Set `PLIMITF_EXCLUSIVE` flag
3. Return new exclusive limit structure

**Rationale:** Multi-threaded processes need private limits to avoid races when multiple LWPs modify limits simultaneously.

### Limit Modification

#### `plimit_modify`

Source: `kern_plimit.c:233-289`

Atomically modify a limit:

1. If `pl_refcnt > 1` → allocate private copy (copy-on-write)
2. Set `PLIMITF_EXCLUSIVE` if process has LWPs
3. Update limit value
4. Release old limit structure

**Locking:** Uses process token (`&p->p_token`) for atomicity.

#### `dosetrlimit`

Source: `kern_plimit.c:291-444`

System call handler for `setrlimit()`:

1. Validate new limits (soft ≤ hard)
2. Check permissions (non-root can only lower hard limit)
3. Call `plimit_modify()` to update
4. Special handling:
   - `RLIMIT_NOFILE` — update `maxfilesperproc` cache
   - `RLIMIT_STACK` — call `vm_map_growstack()` to adjust stack
   - `RLIMIT_CPU` — update `p_cpulimit` (in microseconds)

**Permission check:** Raising hard limits requires superuser privilege.

### Fork Depth Adjustment (`plimit_getadjvalue`)

Source: `kern_plimit.c:446-493`

Adjust limits based on chroot depth:

```c
static uint64_t plimit_getadjvalue(uint64_t v) {
    int depth = chroot_visible_vnodes.depth;
    v -= v * depth * 10 / 100;  /* 10% per chroot level */
    // Max 50% reduction
}
```

**Rationale:** Nested chroot environments (e.g., jails within jails) get progressively reduced limits to prevent resource exhaustion.

### CPU Limit Enforcement

The CPU limit is enforced in `kern_clock.c:statclock()`:

1. Each clock tick, check `p->p_cpulimit`
2. If exceeded, send `SIGXCPU` signal
3. If grace period exceeded, send `SIGKILL`

The limit is stored in **microseconds** (`p_cpulimit`) for efficient comparison.

---

## Resource Accounting (`kern_resource.c`)

### Priority Management

#### Three Priority Types

1. **Nice priority** (`p_nice`) — CPU scheduling priority (-20 to +20)
2. **I/O priority** (`p_ionice`) — Disk I/O priority (0 to 20)
3. **Real-time priority** (`lwp_rtprio`) — Real-time scheduling class

Each type is independent and affects different schedulers.

#### `getpriority`/`setpriority`

Source: `kern_resource.c:84-244`

Adjust nice value:

```c
int setpriority(int which, id_t who, int prio) {
    // which: PRIO_PROCESS, PRIO_PGRP, PRIO_USER
    // prio: PRIO_MIN (-20) to PRIO_MAX (+20)
}
```

**Effects:**
1. Update `p->p_nice`
2. Call `p->p_usched->resetpriority(lp)` for each LWP
3. Reschedule threads with new priority

**Permission:** Non-root can only increase nice (lower priority).

#### `ioprio_get`/`ioprio_set`

Source: `kern_resource.c:246-386`

Adjust I/O priority:

```c
int ioprio_set(int which, int who, int prio) {
    // prio: IOPRIO_MIN (0) to IOPRIO_MAX (20)
}
```

**Effects:**
1. Update `p->p_ionice`
2. Affects disk scheduler (dsched) I/O ordering

**Use case:** Deprioritize background tasks (e.g., backups).

#### `rtprio`/`lwp_rtprio`

Source: `kern_resource.c:388-594`

Real-time priority control:

```c
struct rtprio {
    uint16_t type;   /* RTP_PRIO_REALTIME, NORMAL, IDLE, FIFO */
    uint16_t prio;   /* 0-31 */
};
```

**Classes:**
- `RTP_PRIO_REALTIME` — Hard real-time (requires `SYSCAP_NOSCHED`)
- `RTP_PRIO_FIFO` — FIFO scheduling
- `RTP_PRIO_NORMAL` — Time-sharing
- `RTP_PRIO_IDLE` — Run only when idle

**Permission:** Real-time classes require `SYSCAP_NOSCHED` capability.

### CPU Time Accounting

#### `calcru` — Calculate Resource Usage

Source: `kern_resource.c:655-743`

Convert tick counters to timeval:

```c
void calcru(struct lwp *lp, struct timeval *up, struct timeval *sp) {
    // Convert td_uticks → up (user time)
    // Convert td_sticks → sp (system time)
}
```

**Tick sources:**
- `td_uticks` — User-mode microseconds (updated in statclock)
- `td_sticks` — Kernel-mode microseconds (updated in statclock)
- `td_iticks` — Interrupt microseconds

**Algorithm:**
1. Read tick counters atomically
2. Convert ticks to timeval using `sys_cputimer->freq`
3. Handle wraparound and monotonicity

#### `calcru_proc` — Aggregate Process Usage

Source: `kern_resource.c:745-819`

Sum all LWP statistics into process rusage:

```c
void calcru_proc(struct proc *p, struct rusage *ru) {
    FOREACH_LWP_IN_PROC(lp, p) {
        calcru(lp, &utv, &stv);
        timeradd(&ru->ru_utime, &utv);
        timeradd(&ru->ru_stime, &stv);
    }
}
```

**Aggregated fields:**
- `ru_utime` — Total user CPU time
- `ru_stime` — Total system CPU time
- `ru_minflt` — Minor page faults
- `ru_majflt` — Major page faults
- `ru_inblock` — Block input operations
- `ru_oublock` — Block output operations

#### `getrusage` System Call

Source: `kern_resource.c:821-922`

Retrieve resource usage:

```c
int getrusage(int who, struct rusage *rusage) {
    // who: RUSAGE_SELF, RUSAGE_CHILDREN
}
```

**RUSAGE_SELF:** Returns current process usage (via `calcru_proc`).

**RUSAGE_CHILDREN:** Returns accumulated child usage from `p->p_cru` (updated in `kern_exit.c:wait1()` when reaping children).

### Per-User Resource Tracking (`uidinfo`)

#### `struct uidinfo`

Source: `kern_resource.c:66-82`

Per-user accounting structure:

```c
struct uidinfo {
    uid_t ui_uid;           /* User ID */
    int ui_ref;             /* Reference count */
    int ui_proccnt;         /* Process count */
    int ui_openfiles;       /* Open file count */
    int ui_sbsize;          /* Socket buffer bytes */
    // Hashed in uidinfo_hash
};
```

**Use cases:**
- Enforce `RLIMIT_NPROC` (processes per user)
- Enforce `maxfilesperuser` (open files per user)
- Enforce `RLIMIT_SBSIZE` (socket buffer space per user)

#### `chgproccnt`/`chgsbsize`

Source: `kern_resource.c:1038-1103`

Atomically adjust per-user counters:

```c
int chgproccnt(struct uidinfo *uip, int diff, int max) {
    // Returns 0 if within limit, 1 if exceeded
}

int chgsbsize(struct uidinfo *uip, int *hiwat, int to, int max) {
    // Adjust socket buffer size tracking
}
```

**Atomicity:** Uses `atomic_fetchadd_int()` for lock-free updates.

**Callers:**
- `fork()` → `chgproccnt(uip, 1, maxproc)`
- `exit()` → `chgproccnt(uip, -1, 0)`
- `socket()` → `chgsbsize()` for buffer allocation

---

## Credentials (`kern_prot.c`)

### Data Structures

#### `struct ucred`

Process credentials:

```c
struct ucred {
    int cr_ref;                /* Reference count */
    uid_t cr_uid;              /* Effective user ID */
    uid_t cr_ruid;             /* Real user ID */
    uid_t cr_svuid;            /* Saved user ID */
    gid_t cr_gid;              /* Effective group ID */
    gid_t cr_rgid;             /* Real group ID */
    gid_t cr_svgid;            /* Saved group ID */
    gid_t cr_groups[NGROUPS];  /* Supplementary groups */
    int cr_ngroups;            /* Group count */
    struct prison *cr_prison;  /* Jail info */
    // ... capabilities, labels, etc.
};
```

**Special credentials:**
- `NOCRED` — No credential (internal use)
- `FSCRED` — Filesystem credential (never freed)

### Atomic Copy-on-Write (`cratom`)

Source: `kern_prot.c:113-177`

Ensure exclusive credential before modification:

```c
struct ucred *cratom(struct ucred **cr) {
    if ((*cr)->cr_ref > 1) {
        // Shared → allocate private copy
        struct ucred *ncr = crdup(*cr);
        crfree(*cr);
        *cr = ncr;
    }
    return *cr;
}
```

**Why copy-on-write?**
- Credentials are shared across fork() and threads
- Modification requires atomicity (no races)
- Copy-on-write avoids unnecessary duplication

#### `cratom_proc`

Source: `kern_prot.c:179-209`

Process-level atomization:

```c
struct ucred *cratom_proc(struct proc *p) {
    p->p_ucred = cratom(&p->p_ucred);
    return p->p_ucred;
}
```

**Locking:** Uses process token (`&p->p_token`) for atomicity.

### UID/GID System Calls

#### `getuid`/`geteuid`/`getgid`/`getegid`

Source: `kern_prot.c:211-279`

Retrieve credentials:

```c
uid_t getuid(void)  { return curthread->td_ucred->cr_ruid; }
uid_t geteuid(void) { return curthread->td_ucred->cr_uid; }
```

**Thread vs. process credentials:**
- Threads cache `td_ucred` (pointer to `p->p_ucred`)
- Always consistent due to copy-on-write semantics

#### `setuid`/`seteuid`

Source: `kern_prot.c:281-457`

Change user ID:

```c
int setuid(uid_t uid) {
    // POSIX_APPENDIX_B_4_2_2 semantics
}
```

**Semantics (POSIX_APPENDIX_B_4_2_2):**

For non-superuser:
- Can set euid to ruid or svuid only

For superuser:
- Sets all three: ruid, euid, svuid

**Implementation:**
1. Call `cratom_proc()` to get exclusive credential
2. Update uid fields
3. Call `change_euid()` to transfer uidinfo
4. Mark process as `P_SUGID` (tainted)

#### `change_euid`/`change_ruid`

Source: `kern_prot.c:459-550`

Helper functions to change UID with uidinfo transfer:

```c
void change_euid(uid_t euid) {
    struct uidinfo *new_uip = uifind(euid);
    uireplace(&p->p_ucred->cr_uidinfo, new_uip);
    // Transfer lock file ownership, etc.
}
```

**uidinfo management:**
- `uifind(uid)` — Lookup or create uidinfo (refcounted)
- `uireplace()` — Atomically swap uidinfo pointers
- `uihold()`/`uidrop()` — Reference counting

**Lock file adjustment:** `lf_count_adjust()` transfers file lock ownership.

#### `setreuid`/`setregid`

Source: `kern_prot.c:552-751`

Set real and effective IDs simultaneously:

```c
int setreuid(uid_t ruid, uid_t euid) {
    // Allows swapping ruid ↔ euid (for setuid programs)
}
```

**Use case:** Temporarily drop privileges (swap euid and ruid), perform operation, then restore.

#### `setresuid`/`setresgid`

Source: `kern_prot.c:753-988`

Set real, effective, and saved IDs:

```c
int setresuid(uid_t ruid, uid_t euid, uid_t suid) {
    // Fine-grained control over all three IDs
}
```

**Advantage:** Provides explicit control over saved UID (needed for some security models).

#### `setgroups`/`getgroups`

Source: `kern_prot.c:990-1120`

Manage supplementary groups:

```c
int setgroups(int ngroups, gid_t *groups) {
    // Requires superuser privilege
}
```

**Limit:** `NGROUPS` (typically 16-64 depending on configuration).

### Permission Checking

#### `p_trespass`

Source: `kern_prot.c:1256-1332`

Check if process A can signal/ptrace process B:

```c
int p_trespass(struct ucred *cr1, struct ucred *cr2) {
    // Returns 0 if allowed, errno otherwise
}
```

**Rules:**
1. Root can always signal others
2. Same uid → allowed
3. Same ruid and target not setuid → allowed
4. Otherwise → EPERM

**Security:** Prevents unprivileged processes from interfering with setuid processes.

### Process/Session/Group IDs

#### `getpid`/`getppid`

Source: `kern_prot.c:1415-1478`

Retrieve process/parent IDs:

```c
pid_t getpid(void)  { return curproc->p_pid; }
pid_t getppid(void) { return curproc->p_pptr->p_pid; }
```

#### `setsid` — Create New Session

Source: `kern_prot.c:1532-1597`

Become session leader:

```c
pid_t setsid(void) {
    // Create new session and process group
}
```

**Effects:**
1. Allocate new session ID (equal to pid)
2. Allocate new process group ID (equal to pid)
3. Detach from controlling terminal
4. Become session leader

**Restrictions:** Cannot be called by process group leader.

#### `setpgid` — Set Process Group

Source: `kern_prot.c:1599-1749`

Change process group membership:

```c
int setpgid(pid_t pid, pid_t pgid) {
    // Move process to different process group
}
```

**Restrictions:**
1. Can only set own pgid or child's pgid before exec
2. Target must be in same session
3. Cannot move across session boundaries

### Credential Tainting (`setsugid`)

Source: `kern_prot.c:1751-1784`

Mark process as tainted (changed credentials):

```c
void setsugid(void) {
    p->p_flags |= P_SUGID;
}
```

**Effects:**
- Disables core dumps (security)
- Disables ptrace attachment
- Prevents privilege escalation exploits

**Callers:**
- `setuid()`, `setgid()` — after changing credentials
- `execve()` — when executing setuid binary

---

## Interactions Between Subsystems

### File Descriptors → Resource Limits

`fdalloc()` checks `RLIMIT_NOFILE` before allocating:

```c
if (fd >= p->p_rlimit[RLIMIT_NOFILE].rlim_cur)
    return EMFILE;
```

### File Descriptors → Credentials

File operations use `td_ucred` for permission checks:

```c
int error = VOP_READ(vp, uio, 0, td->td_ucred);
```

### Resource Limits → Fork

`fork()` checks `RLIMIT_NPROC` before creating child:

```c
if (chgproccnt(uip, 1, p->p_rlimit[RLIMIT_NPROC].rlim_cur) > 0)
    return EAGAIN;
```

### Credentials → uidinfo

Changing UID transfers uidinfo:

```c
change_euid(new_uid) {
    uireplace(&cr->cr_uidinfo, uifind(new_uid));
}
```

This updates per-user resource tracking atomically.

---

## Key Design Principles

### 1. Copy-on-Write for Sharing

Both `plimit` and `ucred` use reference counting with copy-on-write:

- Cheap sharing across fork()
- Atomic modification when needed
- No races in multi-threaded processes

### 2. Thread-Local Caching

File descriptor cache (`td_fdcache`) avoids expensive atomic operations:

- 16-entry cache per thread
- Borrowed references (mode 2) skip refcount ops
- Cache coherency via `fclearcache()`

### 3. Per-User Resource Tracking

`uidinfo` provides global accounting per user:

- Prevents single user from exhausting system resources
- Enforced atomically with `chgproccnt`/`chgsbsize`
- Hashed for efficient lookup

### 4. Binary Tree Allocation

File descriptor allocation uses binary tree traversal:

- O(log n) allocation even with sparse tables
- Efficient reuse of low-numbered descriptors
- Minimizes table growth

### 5. Limit Enforcement Points

Resource limits are enforced at allocation points:

- `RLIMIT_NOFILE` — in `fdalloc()`
- `RLIMIT_NPROC` — in `fork()`
- `RLIMIT_CPU` — in `statclock()` (kern_clock.c)
- `RLIMIT_STACK` — in `vm_map_growstack()` (sys/vm)

---

## Summary

Process resource management in DragonFly BSD provides:

1. **Efficient file descriptor management** with thread-local caching and binary tree allocation
2. **Copy-on-write resource limits** shared across fork() with atomic modification
3. **Multi-level priority control** (nice, ionice, rtprio) for CPU and I/O scheduling
4. **Atomic credential management** with POSIX semantics and per-user accounting
5. **System-wide resource tracking** preventing exhaustion attacks

The design emphasizes:
- **Atomicity** through copy-on-write and tokens
- **Performance** through caching and lock-free algorithms
- **Isolation** through per-user limits and permission checks
- **Scalability** through efficient data structures (binary tree, hash tables)

These subsystems interact closely with process lifecycle (fork/exec/exit), virtual filesystem (file operations), and virtual memory (stack limits), forming the foundation of resource management in the kernel.
