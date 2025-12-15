# POSIX Message Queues

POSIX message queues provide named, priority-based message passing between processes. DragonFly's implementation (`sys/kern/sys_mqueue.c`) follows IEEE Std 1003.1-2001 and was derived from NetBSD.

## Data Structures

### Message Queue

The `struct mqueue` (`sys/sys/mqueue.h:77`) represents a message queue:

```c
struct mqueue {
    char            mq_name[MQ_NAMELEN];
    struct lock     mq_mtx;
    int             mq_send_cv;     /* sleep channel for senders */
    int             mq_recv_cv;     /* sleep channel for receivers */
    struct mq_attr  mq_attrib;
    /* Notification */
    struct kqinfo   mq_rkq;         /* kqueue for read */
    struct kqinfo   mq_wkq;         /* kqueue for write */
    struct sigevent mq_sig_notify;
    struct proc *   mq_notify_proc;
    /* Permissions */
    mode_t          mq_mode;
    uid_t           mq_euid;
    gid_t           mq_egid;
    /* Message storage */
    u_int           mq_refcnt;
    TAILQ_HEAD(, mq_msg) mq_head[1 + MQ_PQSIZE];
    uint32_t        mq_bitmap;
    LIST_ENTRY(mqueue) mq_list;
    struct timespec mq_atime;
    struct timespec mq_mtime;
    struct timespec mq_btime;
};
```

### Message Attributes

The `struct mq_attr` (`sys/sys/mqueue.h:40`) holds queue configuration:

```c
struct mq_attr {
    long    mq_flags;       /* O_NONBLOCK, MQ_UNLINK, MQ_RECEIVE */
    long    mq_maxmsg;      /* maximum messages in queue */
    long    mq_msgsize;     /* maximum message size */
    long    mq_curmsgs;     /* current message count */
};
```

### Message Structure

Individual messages use `struct mq_msg` (`sys/sys/mqueue.h:111`):

```c
struct mq_msg {
    TAILQ_ENTRY(mq_msg) msg_queue;
    size_t              msg_len;
    u_int               msg_prio;
    int8_t              msg_ptr[1];     /* variable-length data */
};
```

The `msg_ptr` field uses the struct hack pattern - actual allocation includes space for the message body.

## Priority Queue Implementation

### Constant-Time Insertion

Messages are stored in priority queues for O(1) insertion. The queue uses 32 priority levels (`MQ_PQSIZE = 32`) plus one reserved queue:

```c
#define MQ_PQSIZE   32      /* number of priority queues */
#define MQ_PQRESQ   0       /* reserved queue index */
```

The `mq_head` array contains `MQ_PQSIZE + 1` TAILQ heads. Index 0 is reserved for overflow when `mq_prio_max` exceeds 32.

### Bitmap Tracking

A 32-bit bitmap (`mq_bitmap`) tracks which priority queues contain messages:

```c
/* Inserting message at priority msg_prio */
u_int idx = MQ_PQSIZE - msg_prio;
TAILQ_INSERT_TAIL(&mq->mq_head[idx], msg, msg_queue);
mq->mq_bitmap |= (1 << --idx);
```

The priority-to-index mapping (`MQ_PQSIZE - msg_prio`) ensures higher priorities map to lower indices, so `ffs()` (find first set) returns the highest priority queue.

### Receiving Highest Priority

`mq_receive1()` uses `ffs()` on the bitmap to find the highest-priority non-empty queue (`sys_mqueue.c:685-699`):

```c
msg = TAILQ_FIRST(&mq->mq_head[MQ_PQRESQ]);
if (__predict_true(msg == NULL)) {
    idx = ffs(mq->mq_bitmap);
    msg = TAILQ_FIRST(&mq->mq_head[idx]);
}
TAILQ_REMOVE(&mq->mq_head[idx], msg, msg_queue);

/* Clear bit if queue now empty */
if (__predict_true(idx) && TAILQ_EMPTY(&mq->mq_head[idx])) {
    mq->mq_bitmap &= ~(1 << --idx);
}
```

### Reserved Queue

If `mq_prio_max` is increased beyond 32 via sysctl, `mqueue_linear_insert()` (`sys_mqueue.c:204-218`) performs linear insertion into `MQ_PQRESQ`:

```c
static inline void
mqueue_linear_insert(struct mqueue *mq, struct mq_msg *msg)
{
    struct mq_msg *mit;

    TAILQ_FOREACH(mit, &mq->mq_head[MQ_PQRESQ], msg_queue) {
        if (msg->msg_prio > mit->msg_prio)
            break;
    }
    if (mit == NULL)
        TAILQ_INSERT_TAIL(&mq->mq_head[MQ_PQRESQ], msg, msg_queue);
    else
        TAILQ_INSERT_BEFORE(mit, msg, msg_queue);
}
```

## Synchronization

### Lock Ordering

The implementation uses a two-level locking hierarchy (`sys_mqueue.c:33-42`):

```
mqlist_mtx          (global list lock)
  -> mqueue::mq_mtx (per-queue lock)
```

### Global List Lock

`mqlist_mtx` protects:
- The global `mqueue_head` list
- Per-process `p->p_mqueue_cnt` counter

### Per-Queue Lock

Each queue's `mq_mtx` (a `struct lock` with `LK_CANRECURSE`) protects:
- Queue attributes (`mq_attrib`)
- Message queues (`mq_head[]`, `mq_bitmap`)
- Notification state

### Blocking Operations

Senders and receivers block using `lksleep()` with the queue lock held:

```c
/* Receiver waiting for messages */
error = lksleep(&mq->mq_send_cv, &mq->mq_mtx, PCATCH, "mqsend", t);

/* Sender waiting for space */
error = lksleep(&mq->mq_recv_cv, &mq->mq_mtx, PCATCH, "mqrecv", t);
```

Wakeups use `wakeup_one()` to wake a single waiter.

## System Calls

### mq_open()

`sys_mq_open()` (`sys_mqueue.c:414-612`) creates or opens a message queue:

1. Validates access mode flags
2. Copies name from userspace (max `MQ_NAMELEN` = `NAME_MAX + 1`)
3. If `O_CREAT`:
   - Checks per-process limit (`mq_open_max`)
   - Validates or uses default attributes
   - Allocates new `struct mqueue`
4. Allocates file descriptor (`DTYPE_MQUEUE`)
5. Looks up existing queue under `mqlist_mtx`
6. If found: checks permissions with `vaccess()`
7. If not found and `O_CREAT`: inserts new queue into global list
8. Returns descriptor

Default attributes when none specified:
```c
attr.mq_maxmsg = mq_def_maxmsg;     /* 32 */
attr.mq_msgsize = MQ_DEF_MSGSIZE - sizeof(struct mq_msg);  /* ~1000 */
```

### mq_send() / mq_timedsend()

`mq_send1()` (`sys_mqueue.c:782-913`) sends a message:

1. Validates priority (< `mq_prio_max`)
2. Allocates message structure with data
3. Copies data from userspace
4. Acquires queue via `mqueue_get()`
5. Validates message size against `mq_msgsize`
6. If queue full and blocking: sleeps on `mq_recv_cv`
7. Inserts message into appropriate priority queue
8. If notification registered and queue was empty: signals process
9. Increments `mq_curmsgs`, wakes one receiver

### mq_receive() / mq_timedreceive()

`mq_receive1()` (`sys_mqueue.c:623-725`) receives a message:

1. Acquires queue via `mqueue_get()`
2. Validates buffer size (>= `mq_msgsize`)
3. If queue empty and blocking: sleeps on `mq_send_cv`
4. Finds highest-priority message via bitmap
5. Removes message from queue
6. Decrements `mq_curmsgs`, wakes one sender
7. Copies message data and priority to userspace
8. Frees message structure

### mq_notify()

`sys_mq_notify()` (`sys_mqueue.c:956-1002`) registers for notification:

```c
if (uap->notification) {
    if (mq->mq_notify_proc == NULL) {
        memcpy(&mq->mq_sig_notify, &sig, sizeof(struct sigevent));
        mq->mq_notify_proc = curproc;
    } else {
        error = EBUSY;  /* already registered */
    }
} else {
    mq->mq_notify_proc = NULL;  /* unregister */
}
```

Only `SIGEV_SIGNAL` notification is fully implemented. The signal is sent via `ksignal()` when a message arrives to an empty queue.

### mq_getattr() / mq_setattr()

`sys_mq_getattr()` returns current attributes. `sys_mq_setattr()` only modifies `O_NONBLOCK`:

```c
if (nonblock)
    mq->mq_attrib.mq_flags |= O_NONBLOCK;
else
    mq->mq_attrib.mq_flags &= ~O_NONBLOCK;
```

### mq_unlink()

`sys_mq_unlink()` (`sys_mqueue.c:1077-1142`) marks a queue for deletion:

1. Looks up queue by name
2. Checks permissions (owner or root)
3. Sets `MQ_UNLINK` flag
4. Wakes all waiters
5. If no references: removes from list and destroys
6. Otherwise: last `mq_close()` destroys it

### mq_close()

`sys_mq_close()` delegates to `sys_close()`. The actual cleanup happens in `mq_close_fop()` (`sys_mqueue.c:373-408`):

```c
p->p_mqueue_cnt--;
mq->mq_refcnt--;

if (mq->mq_notify_proc == p)
    mq->mq_notify_proc = NULL;

if (mq->mq_refcnt == 0 && (mq->mq_attrib.mq_flags & MQ_UNLINK)) {
    LIST_REMOVE(mq, mq_list);
    destroy = true;
}
```

## Timeout Handling

### abstimeout2timo()

Converts absolute `timespec` to relative ticks (`sys_mqueue.c:240-259`):

```c
int
abstimeout2timo(struct timespec *ts, int *timo)
{
    error = itimespecfix(ts);
    if (error)
        return error;
    
    getnanotime(&tsd);
    timespecsub(ts, &tsd, ts);      /* ts = ts - now */
    
    if (ts->tv_sec < 0 || (ts->tv_sec == 0 && ts->tv_nsec <= 0))
        return ETIMEDOUT;           /* already expired */
    
    *timo = tstohz(ts);
    return 0;
}
```

## File Operations

The `mqops` structure (`sys_mqueue.c:97-106`):

```c
static struct fileops mqops = {
    .fo_read = badfo_readwrite,
    .fo_write = badfo_readwrite,
    .fo_ioctl = badfo_ioctl,
    .fo_stat = mq_stat_fop,
    .fo_close = mq_close_fop,
    .fo_kqfilter = mq_kqfilter_fop,
    .fo_shutdown = badfo_shutdown,
    .fo_seek = badfo_seek
};
```

Note: Direct read/write on the descriptor is not supported - use `mq_send()`/`mq_receive()`.

### kqueue Support

`mq_kqfilter_fop()` supports `EVFILT_READ` and `EVFILT_WRITE`:

- `EVFILT_READ`: ready when `mq_curmsgs > 0`
- `EVFILT_WRITE`: ready when `mq_curmsgs < mq_maxmsg`

## Flags

### User-Visible Flags

| Flag | Usage |
|------|-------|
| `O_RDONLY` | Open for receive only |
| `O_WRONLY` | Open for send only |
| `O_RDWR` | Open for send and receive |
| `O_CREAT` | Create queue if not exists |
| `O_EXCL` | Fail if queue exists (with `O_CREAT`) |
| `O_NONBLOCK` | Non-blocking operations |

### Internal Flags

| Flag | Value | Description |
|------|-------|-------------|
| `MQ_UNLINK` | 0x10000000 | Queue marked for deletion |
| `MQ_RECEIVE` | 0x20000000 | Receiver is waiting (suppresses notification) |

## Sysctl Tunables

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kern.mqueue.mq_open_max` | 512 | Max descriptors per process |
| `kern.mqueue.mq_prio_max` | 32 | Max message priority |
| `kern.mqueue.mq_max_msgsize` | 16384 | Max message size |
| `kern.mqueue.mq_def_maxmsg` | 32 | Default max messages per queue |
| `kern.mqueue.mq_max_maxmsg` | 512 | Max allowed messages per queue |

## Resource Limits

Each process tracks open mqueue descriptors in `p->p_mqueue_cnt`. Opening a queue fails with `EMFILE` if the count reaches `mq_open_max`.

## Source Reference

| File | Description |
|------|-------------|
| `sys/kern/sys_mqueue.c` | POSIX message queue implementation |
| `sys/sys/mqueue.h` | Message queue structures and constants |
