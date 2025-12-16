# System Calls

This document covers the system call dispatch mechanism, generic I/O syscalls,
the ioctl interface, I/O multiplexing (select/poll), and process tracing (ptrace).

## Overview

System calls are the interface between user programs and the kernel. When a
user program invokes a system call, the CPU transitions from user mode to
kernel mode, the kernel locates the appropriate handler function, executes it,
and returns the result to the user program.

DragonFly BSD uses a table-driven syscall dispatch mechanism. Each syscall has
an entry in the `sysent[]` array that specifies the handler function and
argument count.

## Key Source Files

| File | Purpose |
|------|---------|
| `sys/sys/sysent.h` | `struct sysent` and `struct sysentvec` definitions |
| `sys/sys/sysmsg.h` | `struct sysmsg` - syscall message structure |
| `sys/kern/syscalls.c` | Generated syscall name table |
| `sys/kern/kern_syscalls.c` | Syscall registration for modules |
| `sys/kern/sys_generic.c` | Generic I/O syscalls (read, write, ioctl, select, poll) |
| `sys/kern/sys_process.c` | ptrace implementation |

## Syscall Dispatch Mechanism

### The sysent Structure

Each system call is described by a `struct sysent` entry (`sys/sys/sysent.h:44`):

```c
struct sysent {
    int32_t   sy_narg;    /* number of arguments */
    uint32_t  sy_rsize;   /* sizeof(result) */
    sy_call_t *sy_call;   /* start function */
    sy_call_t *sy_abort;  /* abort function (only if start was async) */
};
```

The global `sysent[]` array contains entries for all system calls. Syscall
numbers index directly into this array.

### The sysmsg Structure

Every syscall handler receives a `struct sysmsg` that carries the return value
back to userspace (`sys/sys/sysmsg.h:58`):

```c
struct sysmsg {
    union {
        void    *resultp;       /* misc pointer data or result */
        int     iresult;        /* standard 'int'eger result */
        long    lresult;        /* long result */
        size_t  szresult;       /* size_t result */
        long    fds[2];         /* double result (e.g., pipe) */
        __int32_t result32;     /* 32 bit result */
        __int64_t result64;     /* 64 bit result */
        __off_t offset;         /* off_t result */
        register_t reg;
    } sm_result;
    struct trapframe *sm_frame; /* saved user context */
    union sysunion extargs;     /* if more than 6 args */
};
```

The union allows syscalls to return different types efficiently. Common accessor
macros include:
- `sysmsg->sysmsg_result` - standard int result
- `sysmsg->sysmsg_szresult` - size_t result (read/write byte counts)
- `sysmsg->sysmsg_fds` - dual result for syscalls like `pipe()`

### Syscall Handler Signature

All syscall handlers follow this signature:

```c
int sys_xxx(struct sysmsg *sysmsg, const struct xxx_args *uap);
```

Where:
- `sysmsg` carries the return value
- `uap` points to the userspace arguments (already copied in)
- The function returns an errno value (0 on success)

### Execution Vector (sysentvec)

Different ABIs (native, Linux emulation, etc.) use different `struct sysentvec`
configurations (`sys/sys/sysent.h:56`):

```c
struct sysentvec {
    int             sv_size;        /* number of entries */
    struct sysent   *sv_table;      /* pointer to sysent */
    int             sv_sigsize;     /* size of signal translation table */
    int             *sv_sigtbl;     /* signal translation table */
    int             sv_errsize;     /* size of errno translation table */
    int             *sv_errtbl;     /* errno translation table */
    int             (*sv_transtrap)(int, int);  /* trap translation */
    int             (*sv_fixup)(register_t **, struct image_params *);
    void            (*sv_sendsig)(...);         /* signal delivery */
    char            *sv_sigcode;    /* sigtramp code */
    int             *sv_szsigcode;  /* sigtramp size */
    char            *sv_name;       /* ABI name */
    int             (*sv_coredump)(...);        /* core dump function */
    int             (*sv_imgact_try)(struct image_params *);
    int             sv_minsigstksz; /* minimum signal stack size */
};
```

This allows the kernel to support multiple system call ABIs simultaneously.

## Generic I/O Syscalls

The generic I/O syscalls are implemented in `sys/kern/sys_generic.c`.

### read / write

The `sys_read()` and `sys_write()` functions (`sys_generic.c:123`, `sys_generic.c:329`)
build a `struct uio` describing the I/O operation and delegate to `kern_preadv()`
or `kern_pwritev()`.

```c
int sys_read(struct sysmsg *sysmsg, const struct read_args *uap)
{
    struct uio auio;
    struct iovec aiov;

    aiov.iov_base = uap->buf;
    aiov.iov_len = uap->nbyte;
    auio.uio_iov = &aiov;
    auio.uio_iovcnt = 1;
    auio.uio_offset = -1;           /* use file position */
    auio.uio_resid = uap->nbyte;
    auio.uio_rw = UIO_READ;
    auio.uio_segflg = UIO_USERSPACE;
    auio.uio_td = curthread;

    error = kern_preadv(uap->fd, &auio, 0, &sysmsg->sysmsg_szresult);
    return error;
}
```

Key points:
- `uio_offset = -1` means use the file's current position
- `uio_segflg = UIO_USERSPACE` indicates the buffer is in user address space
- The byte count is returned via `sysmsg->sysmsg_szresult`

### readv / writev (Scatter-Gather I/O)

The vectored variants (`sys_readv`, `sys_writev`) use `iovec_copyin()` to copy
the iovec array from userspace, then proceed similarly:

```c
int sys_readv(struct sysmsg *sysmsg, const struct readv_args *uap)
{
    struct iovec aiov[UIO_SMALLIOV], *iov = NULL;

    error = iovec_copyin(uap->iovp, &iov, aiov, uap->iovcnt, &auio.uio_resid);
    /* ... build uio ... */
    error = kern_preadv(uap->fd, &auio, 0, &sysmsg->sysmsg_szresult);
    iovec_free(&iov, aiov);
    return error;
}
```

The `UIO_SMALLIOV` optimization avoids kmalloc for small iovec counts (typically 8).

### Positioned I/O (pread/pwrite)

DragonFly provides extended positioned I/O via `sys_extpread()` and `sys_extpwritev()`.
These accept an explicit offset and flags, allowing atomic read/write at a
specific file position without affecting the file pointer.

### The File Operations Layer

All I/O ultimately goes through file operations (`fo_read`, `fo_write`) defined
per file type. See [resources.md](resources.md) for file descriptor management.

## The ioctl Interface

### Overview

The `ioctl()` syscall provides device-specific control operations. It's
implemented by `sys_ioctl()` (`sys_generic.c:537`) which delegates to
`mapped_ioctl()`.

### ioctl Command Encoding

ioctl commands encode direction and size in the command number:
- `IOC_VOID` - no data transfer
- `IOC_IN` - data flows from user to kernel
- `IOC_OUT` - data flows from kernel to user
- `IOCPARM_LEN(cmd)` - extracts the data size

### mapped_ioctl()

The `mapped_ioctl()` function (`sys_generic.c:558`) handles:

1. **Command translation** - For emulation layers, commands can be remapped
2. **Data copyin/copyout** - Based on IOC_IN/IOC_OUT flags
3. **Built-in commands** - FIONBIO, FIOASYNC, FIOCLEX, FIONCLEX
4. **Delegation** - Calls `fo_ioctl()` for file-type-specific handling

```c
int mapped_ioctl(int fd, u_long com, caddr_t uspc_data,
                 struct ioctl_map *map, struct sysmsg *msg)
{
    /* Handle translation map if provided */
    if (map != NULL) {
        /* ... lookup and translate command ... */
    }

    /* Built-in commands */
    switch (com) {
    case FIONCLEX:  /* clear close-on-exec */
    case FIOCLEX:   /* set close-on-exec */
    case FIONBIO:   /* set/clear non-blocking */
    case FIOASYNC:  /* set/clear async I/O */
        /* ... handle directly ... */
    }

    /* Copy data in/out and call file operation */
    size = IOCPARM_LEN(com);
    if (com & IOC_IN)
        copyin(uspc_data, data, size);

    error = fo_ioctl(fp, com, data, cred, msg);

    if (com & IOC_OUT)
        copyout(data, uspc_data, size);
}
```

### Mapped ioctl Handlers

Subsystems can register ioctl command ranges for translation via
`mapped_ioctl_register_handler()`. This is primarily used for emulation
compatibility layers.

## I/O Multiplexing: select and poll

DragonFly implements `select()` and `poll()` using the kqueue infrastructure
internally. This provides efficient, scalable event notification.

### select()

The `sys_select()` function (`sys_generic.c:798`) and its variant `sys_pselect()`
convert fd_set bitmaps into kqueue events:

```c
int sys_select(struct sysmsg *sysmsg, const struct select_args *uap)
{
    /* Copy timeout if provided */
    if (uap->tv != NULL) {
        copyin(uap->tv, &ktv, sizeof(ktv));
        TIMEVAL_TO_TIMESPEC(&ktv, &kts);
    }

    error = doselect(uap->nd, uap->in, uap->ou, uap->ex, ktsp,
                     &sysmsg->sysmsg_result);
    return error;
}
```

The `doselect()` function (`sys_generic.c:1144`):

1. Copies fd_set bitmaps from userspace
2. Converts each set bit to a kevent (EVFILT_READ, EVFILT_WRITE, EVFILT_EXCEPT)
3. Calls `kern_kevent()` on the per-lwp kqueue
4. Converts returned events back to fd_set bitmaps
5. Copies results to userspace

Key implementation details:
- Uses per-LWP kqueue (`lwp->lwp_kqueue`) for efficiency
- Serial numbers (`lwp->lwp_kqueue_serial`) detect stale events
- Events are registered with `NOTE_OLDAPI` for select/poll compatibility

### poll()

The `sys_poll()` function (`sys_generic.c:1234`) works similarly but uses
`struct pollfd` arrays instead of bitmaps:

```c
int sys_poll(struct sysmsg *sysmsg, const struct poll_args *uap)
{
    if (uap->timeout != INFTIM) {
        ts.tv_sec = uap->timeout / 1000;
        ts.tv_nsec = (uap->timeout % 1000) * 1000 * 1000;
        tsp = &ts;
    }

    error = dopoll(uap->nfds, uap->fds, tsp, &sysmsg->sysmsg_result, 0);
    return error;
}
```

The `dopoll()` function (`sys_generic.c:1620`):

1. Copies pollfd array from userspace
2. For each pollfd, registers appropriate kevents based on `events` field
3. Calls `kern_kevent()` 
4. Maps kevent results back to `revents` fields
5. Copies pollfd array back to userspace

### ppoll() and pselect()

The `sys_ppoll()` and `sys_pselect()` variants add:
- Precise timespec timeout (instead of timeval/milliseconds)
- Atomic signal mask manipulation during the wait

Signal mask handling:
```c
if (uap->sigmask != NULL) {
    lp->lwp_oldsigmask = lp->lwp_sigmask;
    lp->lwp_sigmask = sigmask;
    /* ... do poll/select ... */
    if (error == EINTR)
        lp->lwp_flags |= LWP_OLDMASK;  /* restore after signal handler */
    else
        lp->lwp_sigmask = lp->lwp_oldsigmask;  /* restore immediately */
}
```

### Event Flag Mapping

| poll events | kqueue filter | Notes |
|-------------|---------------|-------|
| POLLIN, POLLRDNORM | EVFILT_READ | Normal read data |
| POLLOUT, POLLWRNORM | EVFILT_WRITE | Write possible |
| POLLPRI, POLLRDBAND | EVFILT_EXCEPT | OOB/urgent data |
| POLLHUP | EV_HUP flag | Hangup detected |
| POLLERR | EV_EOF with fflags | Error condition |
| POLLNVAL | EV_ERROR with EBADF | Bad file descriptor |

## Process Tracing (ptrace)

The `ptrace()` syscall enables debuggers to control and inspect other processes.
Implementation is in `sys/kern/sys_process.c`.

### Overview

```c
int sys_ptrace(struct sysmsg *sysmsg, const struct ptrace_args *uap)
{
    /* Copy register structures if needed */
    switch (uap->req) {
    case PT_SETREGS:
        copyin(uap->addr, &r.reg, sizeof(r.reg));
        break;
    /* ... */
    }

    error = kern_ptrace(curp, uap->req, uap->pid, addr, uap->data,
                        &sysmsg->sysmsg_result);

    /* Copy results out */
    switch (uap->req) {
    case PT_GETREGS:
        copyout(&r.reg, uap->addr, sizeof(r.reg));
        break;
    /* ... */
    }
}
```

### ptrace Requests

| Request | Description |
|---------|-------------|
| `PT_TRACE_ME` | Mark self as traced (child calls this) |
| `PT_ATTACH` | Attach to existing process |
| `PT_DETACH` | Detach from traced process |
| `PT_CONTINUE` | Resume execution |
| `PT_STEP` | Single-step one instruction |
| `PT_KILL` | Kill traced process |
| `PT_READ_I/D` | Read instruction/data memory |
| `PT_WRITE_I/D` | Write instruction/data memory |
| `PT_IO` | Bulk memory read/write |
| `PT_GETREGS` | Get general registers |
| `PT_SETREGS` | Set general registers |
| `PT_GETFPREGS` | Get floating-point registers |
| `PT_SETFPREGS` | Set floating-point registers |
| `PT_GETDBREGS` | Get debug registers |
| `PT_SETDBREGS` | Set debug registers |

### Security Checks

The `kern_ptrace()` function (`sys_process.c:290`) enforces:

1. **PT_TRACE_ME** - Always allowed (process traces itself)
2. **PT_ATTACH** requires:
   - Cannot trace self
   - Target not already traced
   - Same UID or root privileges
   - Cannot trace init at securelevel > 0
   - Target not currently in exec
3. **Other requests** require:
   - Target is traced (`P_TRACED` flag)
   - Tracer is the parent (`p->p_pptr == curp`)
   - Target is stopped (`p->p_stat == SSTOP`)

### Memory Access

Memory read/write uses procfs infrastructure:
```c
case PT_READ_I:
case PT_READ_D:
    iov.iov_base = &tmp;
    iov.iov_len = sizeof(int);
    uio.uio_offset = (off_t)(uintptr_t)addr;
    uio.uio_rw = UIO_READ;
    error = procfs_domem(curp, lp, NULL, &uio);
    *res = tmp;
    break;
```

For bulk I/O, `PT_IO` uses a `struct ptrace_io_desc`:
```c
struct ptrace_io_desc {
    int     piod_op;        /* PIOD_READ_D, PIOD_WRITE_I, etc. */
    void    *piod_offs;     /* offset in traced process */
    void    *piod_addr;     /* buffer in tracer */
    size_t  piod_len;       /* length */
};
```

### Process Events (stopevent)

The `stopevent()` function (`sys_process.c:744`) stops a process for procfs
events, allowing debuggers to intercept specific operations:

```c
void stopevent(struct proc *p, unsigned int event, unsigned int val)
{
    p->p_xstat = val;
    p->p_stype = event;
    p->p_step = 1;
    wakeup(&p->p_stype);  /* wake PIOCWAIT waiters */
    tsleep(&p->p_step, ...);  /* wait for PIOCCONT */
}
```

## Syscall Registration for Modules

Kernel modules can register new system calls dynamically using the functions
in `sys/kern/kern_syscalls.c`.

### Registration API

```c
int syscall_register(int *offset, struct sysent *new_sysent,
                     struct sysent *old_sysent);
int syscall_deregister(int *offset, struct sysent *old_sysent);
```

If `*offset == NO_SYSCALL`, the kernel finds an available slot (one marked
with `sys_lkmnosys`). Otherwise, it uses the specified slot.

### SYSCALL_MODULE Macro

The `SYSCALL_MODULE` macro (`sys/sys/sysent.h:96`) simplifies module creation:

```c
SYSCALL_MODULE(name, offset, new_sysent, evh, arg)
```

This creates the necessary module data structures and registers the module
with `syscall_module_handler()` as the event handler.

### Module Event Handler

The `syscall_module_handler()` function (`kern_syscalls.c:80`) handles:
- `MOD_LOAD` - Calls `syscall_register()`, stores slot in module-specific data
- `MOD_UNLOAD` - Calls `syscall_deregister()` to restore original entry

## See Also

- [processes.md](processes.md) - Process lifecycle (for ptrace context)
- [signals.md](signals.md) - Signal handling (for ptrace signal delivery)
- [resources.md](resources.md) - File descriptors and file operations
- [ipc/sockets.md](ipc/sockets.md) - Socket I/O operations
- [kld.md](kld.md) - Kernel module loading (for syscall modules)
