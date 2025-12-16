# kqueue/kevent Event Notification

The kqueue/kevent subsystem provides a scalable, unified event notification
mechanism for monitoring file descriptors, processes, signals, timers, and
user-defined events. It supersedes traditional `select()` and `poll()`
interfaces with O(1) event delivery and extensible filter-based architecture.

**Source files:**

- `sys/kern/kern_event.c` - Core kqueue/kevent implementation (2,133 lines)
- `sys/sys/event.h` - Public API definitions and structures (285 lines)

## Overview

### Design Philosophy

The kqueue mechanism addresses fundamental limitations of `select()` and
`poll()`:

| Aspect | select/poll | kqueue |
|--------|-------------|--------|
| Registration | Per-call | Persistent |
| Scalability | O(n) per call | O(1) delivery |
| Event types | FD-centric | Unified filters |
| Edge/level | Level only | Both supported |
| Extensibility | None | Filter plugins |

Key design principles:

1. **Separation of registration and retrieval** - Events are registered once
   and remain active until explicitly removed
2. **Filter abstraction** - All event sources use a common filter interface
3. **Edge-triggered delivery** - Events report state changes, not just state
4. **Kernel note (knote)** - Each registration creates a persistent kernel
   object tracking the event source

### Architecture

```
    User Space                         Kernel Space
    +----------+                       +------------------+
    | kevent() |---------------------->| sys_kevent()     |
    +----------+                       +------------------+
         |                                     |
         v                                     v
    +-----------+                      +---------------+
    | changelist|                      | kqueue_register|
    | eventlist |                      +---------------+
    +-----------+                              |
                                               v
                              +--------------------------------+
                              |           struct kqueue        |
                              |  +---------------------------+ |
                              |  | kq_knlist (active knotes) | |
                              |  +---------------------------+ |
                              |  | kq_knpend (pending events)| |
                              |  +---------------------------+ |
                              |  | kq_count (pending count)  | |
                              |  +---------------------------+ |
                              +--------------------------------+
                                               |
                    +--------------------------+---------------------------+
                    |                          |                           |
                    v                          v                           v
             +------------+             +------------+              +------------+
             | struct     |             | struct     |              | struct     |
             | knote      |             | knote      |              | knote      |
             | (EVFILT_   |             | (EVFILT_   |              | (EVFILT_   |
             |  READ)     |             |  PROC)     |              |  TIMER)    |
             +------------+             +------------+              +------------+
                    |                          |                           |
                    v                          v                           v
             +------------+             +------------+              +------------+
             | filterops  |             | filterops  |              | filterops  |
             | f_attach   |             | f_attach   |              | f_attach   |
             | f_detach   |             | f_detach   |              | f_detach   |
             | f_event    |             | f_event    |              | f_event    |
             +------------+             +------------+              +------------+
                    |                          |                           |
                    v                          v                           v
             [file/socket]              [process]                   [timer callout]
```

## Data Structures

### struct kevent (User-Facing)

The user-visible event structure passed to/from `kevent()`:

```c
/* sys/sys/event.h:70 */
struct kevent {
    uintptr_t   ident;      /* identifier for this event */
    short       filter;     /* filter for event */
    u_short     flags;      /* action flags for kqueue */
    u_int       fflags;     /* filter-specific flags */
    intptr_t    data;       /* filter-specific data value */
    void        *udata;     /* opaque user data identifier */
};
```

Field semantics vary by filter type:

| Field | EVFILT_READ | EVFILT_PROC | EVFILT_TIMER |
|-------|-------------|-------------|--------------|
| ident | File descriptor | Process ID | Arbitrary ID |
| fflags | (unused) | NOTE_EXIT, etc. | NOTE_SECONDS, etc. |
| data | Bytes available | Exit status | Expirations |

### struct knote (Kernel-Internal)

The kernel's representation of a registered event:

```c
/* sys/sys/event.h:117 */
struct knote {
    SLIST_ENTRY(knote)  kn_link;    /* for fd/object list */
    TAILQ_ENTRY(knote)  kn_kqlink;  /* for kq_knlist */
    SLIST_ENTRY(knote)  kn_next;    /* for kqinfo */
    TAILQ_ENTRY(knote)  kn_tqe;     /* for kq_knpend */
    struct kqueue       *kn_kq;     /* owning kqueue */
    struct kevent       kn_kevent;  /* copy of user's kevent */
    int                 kn_status;  /* KN_* status flags */
    int                 kn_sfflags; /* saved filter flags */
    intptr_t            kn_sdata;   /* saved data field */
    union {
        struct file     *p_fp;      /* file pointer (FILTEROP_ISFD) */
        struct proc     *p_proc;    /* process pointer */
        struct kqinfo   *p_kqi;     /* kqinfo pointer */
    } kn_ptr;
    struct filterops    *kn_fop;    /* filter operations */
    caddr_t             kn_hook;    /* filter-private data */
    int                 kn_lkflags; /* sync lock flags */
};

#define kn_id       kn_kevent.ident
#define kn_filter   kn_kevent.filter
#define kn_flags    kn_kevent.flags
#define kn_fflags   kn_kevent.fflags
#define kn_data     kn_kevent.data
#define kn_fp       kn_ptr.p_fp
```

### struct kqueue

The kqueue descriptor structure:

```c
/* sys/kern/kern_event.c:111 */
struct kqueue {
    struct kqinfo       kq_kqinfo;      /* knotes attached to kqueue */
    TAILQ_HEAD(, knote) kq_knpend;      /* pending knotes */
    TAILQ_HEAD(, knote) kq_knlist;      /* all knotes for this kqueue */
    int                 kq_count;       /* number of pending events */
    int                 kq_state;       /* KQ_* state flags */
    struct sigio        *kq_sigio;      /* for SIGIO delivery */
    struct filedesc     *kq_fdp;        /* file descriptor table */
    struct thread       *kq_sleep_owner;/* sleeping thread */
    int                 kq_sleep_cnt;   /* sleep reference count */
};

/* kqueue state flags */
#define KQ_ASYNC        0x0002  /* async I/O in progress */
#define KQ_SLEEP        0x0004  /* kqueue is sleeping */
```

### struct filterops

Filter operation vectors defining event source behavior:

```c
/* sys/sys/event.h:91 */
struct filterops {
    u_short f_flags;                            /* FILTEROP_* flags */
    int     (*f_attach)(struct knote *kn);      /* attach to event source */
    void    (*f_detach)(struct knote *kn);      /* detach from source */
    int     (*f_event)(struct knote *kn, long hint); /* check/filter event */
};

/* filterops flags */
#define FILTEROP_ISFD       0x0001  /* ident is a file descriptor */
#define FILTEROP_MPSAFE     0x0002  /* filter is MP-safe */
```

### knote Status Flags

```c
/* sys/sys/event.h:106 */
#define KN_ACTIVE       0x0001  /* event has been triggered */
#define KN_QUEUED       0x0002  /* knote is on kq_knpend queue */
#define KN_DISABLED     0x0004  /* event is disabled */
#define KN_DETACHED     0x0008  /* knote detached from source */
#define KN_REPROCESS    0x0010  /* force reprocessing after release */
#define KN_DELETING     0x0020  /* knote being deleted */
#define KN_PROCESSING   0x0040  /* event processing in progress */
#define KN_WAITING      0x0080  /* thread waiting on processing */
```

## System Calls

### kqueue() - Create Event Queue

```c
int kqueue(void);
```

Creates a new kqueue and returns a file descriptor:

```c
/* sys/kern/kern_event.c:722 */
int
sys_kqueue(struct sysmsg *sysmsg, const struct kqueue_args *uap)
{
    struct thread *td = curthread;
    struct kqueue *kq;
    struct file *fp;
    int fd, error;

    error = falloc(td->td_lwp, &fp, &fd);
    if (error)
        return (error);
    
    kq = kmalloc(sizeof(*kq), M_KQUEUE, M_WAITOK | M_ZERO);
    TAILQ_INIT(&kq->kq_knpend);
    TAILQ_INIT(&kq->kq_knlist);
    kq->kq_fdp = td->td_proc->p_fd;
    
    fp->f_type = DTYPE_KQUEUE;
    fp->f_flag = FREAD | FWRITE;
    fp->f_ops = &kqueueops;
    fp->f_data = kq;
    
    fsetfd(kq->kq_fdp, fp, fd);
    fdrop(fp);
    sysmsg->sysmsg_result = fd;
    return (0);
}
```

The kqueue file descriptor supports:

- `close()` - Destroys kqueue and all registered knotes
- `kevent()` - Register and retrieve events
- `poll()`/`select()` - Check for pending events
- `ioctl(FIOASYNC)` - Enable async notification

### kevent() - Register and Retrieve Events

```c
int kevent(int kq, const struct kevent *changelist, int nchanges,
           struct kevent *eventlist, int nevents,
           const struct timespec *timeout);
```

The primary interface for event registration and retrieval:

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `kq` | kqueue file descriptor |
| `changelist` | Array of events to register/modify |
| `nchanges` | Number of changes to process |
| `eventlist` | Array to receive triggered events |
| `nevents` | Maximum events to return |
| `timeout` | Wait timeout (NULL = infinite, 0 = poll) |

**Return value:** Number of events placed in `eventlist`, or -1 on error.

**Implementation flow:**

```c
/* sys/kern/kern_event.c:1053 */
int
sys_kevent(struct sysmsg *sysmsg, const struct kevent_args *uap)
{
    struct thread *td = curthread;
    struct timespec ts, *tsp;
    struct kqueue *kq;
    struct file *fp;
    struct kevent_copyin_args *kap, ka;
    int error;

    /* Validate and get kqueue */
    fp = holdfp(td, uap->fd, -1);
    if (fp == NULL)
        return (EBADF);
    if (fp->f_type != DTYPE_KQUEUE) {
        fdrop(fp);
        return (EBADF);
    }
    kq = fp->f_data;

    /* Copy timeout from user space */
    if (uap->timeout != NULL) {
        error = copyin(uap->timeout, &ts, sizeof(ts));
        if (error)
            goto done;
        tsp = &ts;
    } else {
        tsp = NULL;
    }

    /* Set up copyin/copyout args */
    ka.ka_kq = kq;
    ka.ka_uap = uap;
    
    /* Process changes and scan for events */
    error = kern_kevent(kq, uap->nchanges, &ka, kqueue_copyin,
                        uap->nevents, &ka, kqueue_copyout, tsp);
    
    sysmsg->sysmsg_result = ka.ka_nevents;
done:
    fdrop(fp);
    return (error);
}
```

### kern_kevent() - Core Processing

The internal implementation processes changes then scans for events:

```c
/* sys/kern/kern_event.c:796 */
int
kern_kevent(struct kqueue *kq, int nchanges, void *uchange,
            kevent_copyin_fn *kcopy_in, int nevents, void *uevent,
            kevent_copyout_fn *kcopy_out, struct timespec *tsp)
{
    struct kevent kev;
    int i, n, error;

    /* Phase 1: Process changelist */
    for (i = 0; i < nchanges; i++) {
        error = kcopy_in(uchange, &kev, i);
        if (error)
            break;
        
        kev.flags &= ~EV_SYSFLAGS;
        error = kqueue_register(kq, &kev);
        
        if (error || (kev.flags & EV_RECEIPT)) {
            if (nevents > 0) {
                kev.flags = EV_ERROR;
                kev.data = error;
                kcopy_out(uevent, &kev, n++);
                nevents--;
                error = 0;
            }
        }
    }

    /* Phase 2: Scan for pending events */
    if (nevents > 0 && error == 0) {
        error = kqueue_scan(kq, nevents, uevent, kcopy_out, tsp, &n);
    }

    return (error);
}
```

## Event Flags

### Action Flags

Specify operations when registering events:

| Flag | Value | Description |
|------|-------|-------------|
| `EV_ADD` | 0x0001 | Add event to kqueue (or modify existing) |
| `EV_DELETE` | 0x0002 | Remove event from kqueue |
| `EV_ENABLE` | 0x0004 | Enable event for reporting |
| `EV_DISABLE` | 0x0008 | Disable event (keep registered) |

### Behavior Flags

Control event delivery behavior:

| Flag | Value | Description |
|------|-------|-------------|
| `EV_ONESHOT` | 0x0010 | Delete after first delivery |
| `EV_CLEAR` | 0x0020 | Clear state after retrieval |
| `EV_RECEIPT` | 0x0040 | Force EV_ERROR return on success |
| `EV_DISPATCH` | 0x0080 | Disable after delivery |

### Return Flags

Set by kernel in returned events:

| Flag | Value | Description |
|------|-------|-------------|
| `EV_EOF` | 0x8000 | EOF condition detected |
| `EV_ERROR` | 0x4000 | Error occurred (data = errno) |
| `EV_NODATA` | 0x1000 | EOF with no more data |

### Flag Combinations

Common usage patterns:

```c
/* One-shot read notification */
EV_SET(&kev, fd, EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0, NULL);

/* Level-triggered (re-arm after each retrieval) */
EV_SET(&kev, fd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);

/* Edge-triggered (default - reports state changes) */
EV_SET(&kev, fd, EVFILT_READ, EV_ADD, 0, 0, NULL);

/* Disabled registration (enable later) */
EV_SET(&kev, fd, EVFILT_READ, EV_ADD | EV_DISABLE, 0, 0, NULL);

/* Dispatch mode (disable after delivery, re-enable to re-arm) */
EV_SET(&kev, fd, EVFILT_READ, EV_ADD | EV_DISPATCH, 0, 0, NULL);
```

## Filter Types

### EVFILT_READ (-1) - Read Availability

Reports when data is available for reading:

| Field | Meaning |
|-------|---------|
| ident | File descriptor |
| data | Bytes available to read |
| fflags | NOTE_LOWAT (set low water mark) |

For different descriptor types:

- **Sockets**: Bytes in receive buffer
- **Pipes**: Bytes in pipe buffer
- **FIFOs**: Bytes available
- **TTYs**: Input queue size
- **Vnodes**: (offset - filesize), EV_EOF at EOF

### EVFILT_WRITE (-2) - Write Availability

Reports when writing won't block:

| Field | Meaning |
|-------|---------|
| ident | File descriptor |
| data | Space available in write buffer |
| fflags | NOTE_LOWAT (set low water mark) |

### EVFILT_VNODE (-4) - Vnode Events

Monitor filesystem object changes:

| fflags | Description |
|--------|-------------|
| NOTE_DELETE | Vnode deleted |
| NOTE_WRITE | Write to file |
| NOTE_EXTEND | File extended |
| NOTE_ATTRIB | Attributes changed |
| NOTE_LINK | Link count changed |
| NOTE_RENAME | Vnode renamed |
| NOTE_REVOKE | Access revoked |

### EVFILT_PROC (-5) - Process Events

Monitor process state changes:

```c
/* sys/kern/kern_event.c:394 */
static struct filterops proc_filtops = {
    .f_flags = 0,               /* not fd-based */
    .f_attach = filt_procattach,
    .f_detach = filt_procdetach,
    .f_event = filt_proc,
};
```

| fflags (input) | Description |
|----------------|-------------|
| NOTE_EXIT | Process exited |
| NOTE_FORK | Process forked |
| NOTE_EXEC | Process exec'd |
| NOTE_TRACK | Follow across fork |

| fflags (output) | Description |
|-----------------|-------------|
| NOTE_EXIT | Exit status in data |
| NOTE_FORK | Child PID in data |
| NOTE_EXEC | (no additional data) |
| NOTE_CHILD | Followed child (NOTE_TRACK) |
| NOTE_TRACKERR | Couldn't follow fork |

**Implementation:**

```c
/* sys/kern/kern_event.c:468 */
static int
filt_proc(struct knote *kn, long hint)
{
    u_int event;

    if (kn->kn_sfflags & NOTE_TRACK) {
        /* Handle fork tracking */
    }

    event = (u_int)hint & NOTE_PCTRLMASK;
    if (event == NOTE_EXIT) {
        kn->kn_status |= KN_DETACHED;
        kn->kn_flags |= EV_EOF | EV_NODATA;
        kn->kn_data = kn->kn_ptr.p_proc->p_xstat;
        return (1);
    }

    if (kn->kn_sfflags & event) {
        kn->kn_fflags |= event;
        return (1);
    }
    return (0);
}
```

### EVFILT_SIGNAL (-6) - Signal Events

Monitor signal delivery to the process:

| Field | Meaning |
|-------|---------|
| ident | Signal number |
| data | Delivery count since last retrieval |

Note: Signals are still delivered normally; this provides notification only.

### EVFILT_TIMER (-7) - Timer Events

Create kernel timers:

```c
/* sys/kern/kern_event.c:571 */
static struct filterops timer_filtops = {
    .f_flags = 0,
    .f_attach = filt_timerattach,
    .f_detach = filt_timerdetach,
    .f_event = filt_timer,
};
```

| fflags | Description |
|--------|-------------|
| NOTE_SECONDS | data is in seconds |
| NOTE_MSECONDS | data is in milliseconds |
| NOTE_USECONDS | data is in microseconds |
| NOTE_NSECONDS | data is in nanoseconds |
| NOTE_ABSTIME | Absolute time (not interval) |
| NOTE_ONESHOT | Fire once (alternative to EV_ONESHOT) |

| Field | Meaning |
|-------|---------|
| ident | User-chosen timer ID |
| data | Number of expirations |

**Implementation:**

```c
/* sys/kern/kern_event.c:607 */
static int
filt_timerattach(struct knote *kn)
{
    struct callout *calloutp;
    struct timeval tv;
    int tticks;

    /* Convert timeout to ticks */
    tticks = filt_timer_ticks(kn->kn_sdata, kn->kn_sfflags);
    
    /* Allocate callout */
    calloutp = kmalloc(sizeof(*calloutp), M_KQUEUE, M_WAITOK);
    callout_init_mp(calloutp);
    kn->kn_hook = calloutp;
    
    /* Start timer */
    callout_reset(calloutp, tticks, filt_timerexpire, kn);
    
    return (0);
}
```

### EVFILT_USER (-9) - User-Triggered Events

User-controlled event triggering:

```c
/* sys/kern/kern_event.c:686 */
static struct filterops user_filtops = {
    .f_flags = 0,
    .f_attach = filt_userattach,
    .f_detach = filt_userdetach,
    .f_event = filt_user,
};
```

| fflags | Description |
|--------|-------------|
| NOTE_TRIGGER | Trigger the event |
| NOTE_FFNOP | No fflags operation |
| NOTE_FFAND | AND fflags |
| NOTE_FFOR | OR fflags |
| NOTE_FFCOPY | Copy fflags |
| NOTE_FFCTRLMASK | Mask for control flags |
| NOTE_FFLAGSMASK | Mask for user flags |

Used for inter-thread signaling without pipes or signals.

### EVFILT_FS (-10) - Filesystem Events

Monitor filesystem mount/unmount events:

```c
/* sys/kern/kern_event.c:386 */
static struct filterops fs_filtops = {
    .f_flags = 0,
    .f_attach = filt_fsattach,
    .f_detach = filt_fsdetach,
    .f_event = filt_fs,
};
```

| fflags | Description |
|--------|-------------|
| NOTE_FSMOUNT | Filesystem mounted |
| NOTE_FSUNMOUNT | Filesystem unmounted |
| NOTE_FSUNMOUNTING | Unmount in progress |

### EVFILT_EXCEPT (-8) - Exceptional Conditions

Monitor out-of-band/exceptional conditions:

| Field | Meaning |
|-------|---------|
| ident | File descriptor |
| fflags | NOTE_OOB (out-of-band data) |

## Event Registration

### kqueue_register()

Registers a single event in the kqueue:

```c
/* sys/kern/kern_event.c:1152 */
static int
kqueue_register(struct kqueue *kq, struct kevent *kev)
{
    struct filedesc *fdp;
    struct filterops *fops;
    struct file *fp;
    struct knote *kn;
    int error;

    /* Look up filter operations */
    if (kev->filter < 0 && kev->filter + EVFILT_SYSCOUNT >= 0)
        fops = sysfilt_ops[~kev->filter];
    else
        return (EINVAL);

    /* Handle file descriptor based filters */
    if (fops->f_flags & FILTEROP_ISFD) {
        fp = holdfp(curthread, kev->ident, -1);
        if (fp == NULL)
            return (EBADF);
    }

    /* Look for existing knote */
    lwkt_getpooltoken(kq);
    kn = kqueue_find(kq, kev->filter, kev->ident);

    if (kn == NULL && (kev->flags & EV_ADD)) {
        /* Create new knote */
        kn = knote_alloc();
        kn->kn_kq = kq;
        kn->kn_fop = fops;
        kn->kn_kevent = *kev;
        kn->kn_sfflags = kev->fflags;
        kn->kn_sdata = kev->data;
        
        if (fops->f_flags & FILTEROP_ISFD) {
            kn->kn_fp = fp;
        }
        
        /* Attach to event source */
        error = filter_attach(kn);
        if (error) {
            knote_free(kn);
            goto done;
        }
        
        /* Add to kqueue's knote list */
        TAILQ_INSERT_TAIL(&kq->kq_knlist, kn, kn_kqlink);
        
    } else if (kn != NULL) {
        /* Modify existing knote */
        if (kev->flags & EV_DELETE) {
            kn->kn_status |= KN_DELETING;
            knote_detach_and_drop(kn);
            kn = NULL;
        } else {
            /* Update flags */
            if (kev->flags & EV_DISABLE)
                kn->kn_status |= KN_DISABLED;
            if (kev->flags & EV_ENABLE)
                kn->kn_status &= ~KN_DISABLED;
            kn->kn_kevent.udata = kev->udata;
            
            /* Re-evaluate filter */
            if (filter_event(kn, 0))
                KNOTE_ACTIVATE(kn);
        }
    } else if (!(kev->flags & EV_ADD)) {
        error = ENOENT;
    }

done:
    lwkt_relpooltoken(kq);
    if (fp)
        fdrop(fp);
    return (error);
}
```

### Filter Attachment

When a knote is created, the filter's `f_attach` is called:

```c
/* sys/kern/kern_event.c:1740 */
static int
filter_attach(struct knote *kn)
{
    int error;

    if (kn->kn_fop->f_flags & FILTEROP_ISFD) {
        /* Delegate to file's kqfilter operation */
        error = fo_kqfilter(kn->kn_fp, kn);
    } else {
        /* Call filter's attach directly */
        error = kn->kn_fop->f_attach(kn);
    }
    return (error);
}
```

For file-based filters, `fo_kqfilter()` is called which eventually calls the
file type's specific kqfilter routine (e.g., `soo_kqfilter()` for sockets).

## Event Delivery

### kqueue_scan()

Scans the pending queue and returns triggered events:

```c
/* sys/kern/kern_event.c:1478 */
static int
kqueue_scan(struct kqueue *kq, int maxevents, void *uevent,
            kevent_copyout_fn *kcopy_out, struct timespec *tsp, int *nresp)
{
    struct knote *kn, marker;
    struct kevent kev;
    struct timeval atv, rtv, ttv;
    int count, timeout, error;

    count = maxevents;
    error = 0;

    /* Calculate timeout */
    if (tsp != NULL) {
        if (tsp->tv_sec == 0 && tsp->tv_nsec == 0)
            timeout = 0;  /* Poll mode */
        else
            timeout = tstohz_high(tsp);
    } else {
        timeout = INFSLP;  /* Wait forever */
    }

    lwkt_getpooltoken(kq);

retry:
    /* Insert marker to track our position */
    TAILQ_INSERT_TAIL(&kq->kq_knpend, &marker, kn_tqe);

    while (count > 0) {
        /* Get next pending knote (before marker) */
        kn = TAILQ_FIRST(&kq->kq_knpend);
        if (kn == &marker) {
            TAILQ_REMOVE(&kq->kq_knpend, &marker, kn_tqe);
            
            if (count == maxevents && timeout != 0) {
                /* No events yet, sleep */
                error = kqueue_sleep(kq, timeout);
                if (error == 0 || error == EWOULDBLOCK)
                    goto retry;
                break;
            }
            break;
        }
        TAILQ_REMOVE(&kq->kq_knpend, kn, kn_tqe);
        kn->kn_status &= ~KN_QUEUED;

        /* Acquire knote for processing */
        if (!knote_acquire(kn))
            continue;

        /* Skip disabled or deleted knotes */
        if (kn->kn_status & (KN_DISABLED | KN_DELETING)) {
            knote_release(kn);
            continue;
        }

        /* Re-evaluate filter */
        kn->kn_status |= KN_PROCESSING;
        if (!filter_event(kn, 0)) {
            kn->kn_status &= ~(KN_PROCESSING | KN_ACTIVE);
            knote_release(kn);
            continue;
        }

        /* Copy event to user */
        kev = kn->kn_kevent;
        kev.flags = kn->kn_flags;
        kev.fflags = kn->kn_fflags;
        kev.data = kn->kn_data;
        
        lwkt_relpooltoken(kq);
        error = kcopy_out(uevent, &kev, *nresp);
        lwkt_getpooltoken(kq);
        
        if (error)
            break;
        (*nresp)++;
        count--;

        /* Handle flags */
        if (kn->kn_flags & EV_ONESHOT) {
            kn->kn_status |= KN_DELETING;
            knote_detach_and_drop(kn);
        } else if (kn->kn_flags & EV_CLEAR) {
            kn->kn_fflags = 0;
            kn->kn_data = 0;
            kn->kn_status &= ~(KN_PROCESSING | KN_ACTIVE);
            knote_release(kn);
        } else if (kn->kn_flags & EV_DISPATCH) {
            kn->kn_status |= KN_DISABLED;
            kn->kn_status &= ~(KN_PROCESSING | KN_ACTIVE);
            knote_release(kn);
        } else {
            /* Re-queue if still active */
            if (kn->kn_status & KN_ACTIVE) {
                TAILQ_INSERT_TAIL(&kq->kq_knpend, kn, kn_tqe);
                kn->kn_status |= KN_QUEUED;
            }
            kn->kn_status &= ~KN_PROCESSING;
            knote_release(kn);
        }
    }

    lwkt_relpooltoken(kq);
    return (error);
}
```

### Event Activation

When an event source triggers, it calls `knote()` to activate knotes:

```c
/* sys/kern/kern_event.c:1809 */
void
knote(struct klist *list, long hint)
{
    struct knote *kn;

    SLIST_FOREACH(kn, list, kn_next) {
        if (filter_event(kn, hint))
            KNOTE_ACTIVATE(kn);
    }
}
```

The `KNOTE_ACTIVATE` macro marks the knote active and queues it:

```c
/* sys/kern/kern_event.c:164 */
#define KNOTE_ACTIVATE(kn) do {                                         \
    kn->kn_status |= KN_ACTIVE;                                         \
    if ((kn->kn_status & (KN_QUEUED | KN_DISABLED)) == 0)               \
        knote_enqueue(kn);                                              \
} while (0)
```

```c
/* sys/kern/kern_event.c:178 */
static void
knote_enqueue(struct knote *kn)
{
    struct kqueue *kq = kn->kn_kq;

    KKASSERT((kn->kn_status & KN_QUEUED) == 0);
    TAILQ_INSERT_TAIL(&kq->kq_knpend, kn, kn_tqe);
    kn->kn_status |= KN_QUEUED;
    kq->kq_count++;
    
    /* Wake up any sleeping threads */
    if (kq->kq_state & KQ_SLEEP) {
        kq->kq_state &= ~KQ_SLEEP;
        wakeup(kq);
    }
    
    /* Send SIGIO if requested */
    KNOTE(&kq->kq_kqinfo.ki_note, 0);
}
```

## Synchronization

### Kqueue Locking

Each kqueue is protected by a pool token:

```c
lwkt_getpooltoken(kq);  /* Acquire lock */
/* ... critical section ... */
lwkt_relpooltoken(kq);  /* Release lock */
```

Pool tokens provide per-object serialization without dedicated lock structures.

### Knote Acquire/Release

Knote processing is serialized with acquire/release:

```c
/* sys/kern/kern_event.c:203 */
static int
knote_acquire(struct knote *kn)
{
    if (kn->kn_status & KN_PROCESSING) {
        kn->kn_status |= KN_WAITING;
        tsleep(kn, 0, "kqnote", 0);
        /* Knote may have been deleted while waiting */
        return (0);
    }
    kn->kn_status |= KN_PROCESSING;
    return (1);
}

/* sys/kern/kern_event.c:224 */
static void
knote_release(struct knote *kn)
{
    kn->kn_status &= ~KN_PROCESSING;
    if (kn->kn_status & KN_WAITING) {
        kn->kn_status &= ~KN_WAITING;
        wakeup(kn);
    }
}
```

### Race Handling

The `KN_REPROCESS` flag handles races between event activation and processing:

1. Thread A is processing knote (KN_PROCESSING set)
2. Event source triggers, sets KN_REPROCESS
3. Thread A finishes, sees KN_REPROCESS, re-evaluates filter
4. Ensures no events are lost during processing

### MP-Safe Filters

Filters marked `FILTEROP_MPSAFE` can be called without the kqueue token:

```c
/* sys/kern/kern_event.c:1786 */
static int
filter_event(struct knote *kn, long hint)
{
    if (kn->kn_fop->f_flags & FILTEROP_MPSAFE) {
        return (kn->kn_fop->f_event(kn, hint));
    } else {
        /* Non-MPSAFE filters need additional serialization */
        return (kn->kn_fop->f_event(kn, hint));
    }
}
```

## Integration Points

### File Descriptor Integration

File types implement `fo_kqfilter` to support kqueue:

```c
/* Socket kqfilter - sys/kern/uipc_socket.c */
int
soo_kqfilter(struct file *fp, struct knote *kn)
{
    struct socket *so = fp->f_data;
    struct sockbuf *sb;

    switch (kn->kn_filter) {
    case EVFILT_READ:
        kn->kn_fop = &soread_filtops;
        sb = &so->so_rcv;
        break;
    case EVFILT_WRITE:
        kn->kn_fop = &sowrite_filtops;
        sb = &so->so_snd;
        break;
    case EVFILT_EXCEPT:
        kn->kn_fop = &soexcept_filtops;
        sb = &so->so_rcv;
        break;
    default:
        return (EOPNOTSUPP);
    }

    kn->kn_hook = so;
    SLIST_INSERT_HEAD(&sb->sb_kq.ki_note, kn, kn_next);
    return (0);
}
```

### Socket Integration

Sockets call `KNOTE()` when buffer state changes:

```c
/* sys/kern/uipc_socket.c - on receive */
void
sorwakeup(struct socket *so)
{
    /* ... */
    KNOTE(&so->so_rcv.sb_kq.ki_note, 0);
}

/* sys/kern/uipc_socket.c - on send buffer space */
void
sowwakeup(struct socket *so)
{
    /* ... */
    KNOTE(&so->so_snd.sb_kq.ki_note, 0);
}
```

### Process Integration

Process state changes trigger EVFILT_PROC notifications:

```c
/* sys/kern/kern_exit.c - on exit */
void
exit1(int rv)
{
    /* ... */
    KNOTE(&p->p_klist, NOTE_EXIT);
}

/* sys/kern/kern_fork.c - on fork */
int
fork1(struct lwp *lp, int flags, struct proc **procp)
{
    /* ... */
    KNOTE(&p1->p_klist, NOTE_FORK | p2->p_pid);
}
```

### Vnode Integration

VFS operations trigger EVFILT_VNODE notifications:

```c
/* sys/kern/vfs_subr.c */
void
vn_knote(struct vnode *vp, int flags)
{
    KNOTE(&vp->v_pollinfo.vpi_kqinfo.ki_note, flags);
}

/* Called from various VFS operations */
vn_knote(vp, NOTE_WRITE);   /* On write */
vn_knote(vp, NOTE_ATTRIB);  /* On chmod/chown */
vn_knote(vp, NOTE_DELETE);  /* On unlink */
```

## Helper Macros

### EV_SET

Initialize a kevent structure:

```c
/* sys/sys/event.h:85 */
#define EV_SET(kevp, a, b, c, d, e, f) do {     \
    struct kevent *__kevp = (kevp);             \
    __kevp->ident = (a);                        \
    __kevp->filter = (b);                       \
    __kevp->flags = (c);                        \
    __kevp->fflags = (d);                       \
    __kevp->data = (e);                         \
    __kevp->udata = (f);                        \
} while (0)
```

### Usage Examples

```c
struct kevent changes[3];
struct kevent events[10];
int kq, nev;

kq = kqueue();

/* Monitor socket for read/write */
EV_SET(&changes[0], sockfd, EVFILT_READ, EV_ADD, 0, 0, NULL);
EV_SET(&changes[1], sockfd, EVFILT_WRITE, EV_ADD, 0, 0, NULL);

/* Monitor file for modifications */
EV_SET(&changes[2], filefd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
       NOTE_WRITE | NOTE_DELETE, 0, NULL);

/* Register and wait for events */
nev = kevent(kq, changes, 3, events, 10, NULL);

for (int i = 0; i < nev; i++) {
    if (events[i].flags & EV_ERROR) {
        /* Error in registration */
        errno = events[i].data;
    } else if (events[i].filter == EVFILT_READ) {
        /* Data available: events[i].data bytes */
    } else if (events[i].filter == EVFILT_VNODE) {
        if (events[i].fflags & NOTE_WRITE)
            /* File was modified */;
        if (events[i].fflags & NOTE_DELETE)
            /* File was deleted */;
    }
}
```

## Filter Implementation Guide

To implement a custom filter:

### 1. Define Filter Operations

```c
static struct filterops myfilter_filtops = {
    .f_flags = FILTEROP_MPSAFE,     /* Or 0, or FILTEROP_ISFD */
    .f_attach = myfilter_attach,
    .f_detach = myfilter_detach,
    .f_event = myfilter_event,
};
```

### 2. Implement Attach

```c
static int
myfilter_attach(struct knote *kn)
{
    struct myobject *obj;
    
    /* Validate and find object */
    obj = myobject_find(kn->kn_id);
    if (obj == NULL)
        return (ENOENT);
    
    /* Store reference */
    kn->kn_hook = obj;
    
    /* Add to object's knote list */
    SLIST_INSERT_HEAD(&obj->kq_list, kn, kn_next);
    
    /* Initial event check */
    kn->kn_data = obj->available;
    return (obj->available > 0);
}
```

### 3. Implement Detach

```c
static void
myfilter_detach(struct knote *kn)
{
    struct myobject *obj = kn->kn_hook;
    
    SLIST_REMOVE(&obj->kq_list, kn, knote, kn_next);
}
```

### 4. Implement Event

```c
static int
myfilter_event(struct knote *kn, long hint)
{
    struct myobject *obj = kn->kn_hook;
    
    /* Update event data */
    kn->kn_data = obj->available;
    
    /* Check filter flags */
    if (kn->kn_sfflags & MY_NOTE_THRESHOLD) {
        return (obj->available >= kn->kn_sdata);
    }
    
    return (obj->available > 0);
}
```

### 5. Trigger Events

```c
void
myobject_data_ready(struct myobject *obj)
{
    obj->available++;
    KNOTE(&obj->kq_list, 0);  /* hint = 0 */
}
```

## Performance Considerations

### Scalability

- **O(1) registration**: Adding/removing events is constant time
- **O(active) retrieval**: Only active events are scanned
- **No fd_set copying**: Unlike select(), no per-call data copying

### Best Practices

1. **Use EV_CLEAR for high-frequency events** - Avoids re-registration overhead
2. **Use EV_DISPATCH for one-at-a-time processing** - Prevents thundering herd
3. **Batch changes** - Register multiple events in one kevent() call
4. **Use appropriate timeouts** - Avoid tight polling loops

### Comparison with Alternatives

| Feature | kqueue | epoll (Linux) | poll |
|---------|--------|---------------|------|
| Edge-triggered | Yes | Yes | No |
| One-shot | Yes | Yes | No |
| Timers | Built-in | timerfd | No |
| Signals | Built-in | signalfd | No |
| User events | Yes | eventfd | No |
| File monitoring | Yes | inotify | No |

## See Also

- [Processes](processes.md) - Process management and lifecycle
- [Signals](signals.md) - Signal handling subsystem
- [IPC Overview](ipc.md) - Inter-process communication mechanisms
- [Sockets](ipc/sockets.md) - Socket implementation
- [LWKT](lwkt.md) - Lightweight kernel threads and tokens
