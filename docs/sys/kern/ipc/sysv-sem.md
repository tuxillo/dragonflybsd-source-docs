# System V Semaphores

System V semaphores provide counting semaphores for process synchronization.
DragonFly's implementation derives from FreeBSD and follows the SVID
specification, supporting atomic operations on semaphore sets.

**Source files:**
- `sys/kern/sysv_sem.c` - Implementation
- `sys/sys/sem.h` - Public interface

## Data Structures

### Semaphore Set Descriptor

```c
struct semid_ds {
    struct  ipc_perm sem_perm;  /* permission struct */
    struct  sem *sem_base;      /* pointer to first semaphore */
    unsigned short sem_nsems;   /* number of semaphores in set */
    time_t  sem_otime;          /* last semop() time */
    time_t  sem_ctime;          /* last change time */
};
```

Defined in `sys/sys/sem.h:34-45`.

### Semaphore Pool Entry

```c
struct semid_pool {
    struct lock lk;         /* per-set exclusive lock */
    struct semid_ds ds;     /* the semid_ds descriptor */
    long gen;               /* generation counter */
};
```

Defined in `sys/sys/sem.h:51-55`. The `gen` field detects destroy/recreate
races where credentials might match.

### Individual Semaphore

```c
struct sem {
    u_short semval;     /* current value */
    pid_t   sempid;     /* pid of last operation */
    u_short semncnt;    /* processes waiting for semval > cval */
    u_short semzcnt;    /* processes waiting for semval == 0 */
};
```

Defined in `sys/kern/sysv_sem.c:39-44`.

### Semaphore Operation

```c
struct sembuf {
    unsigned short sem_num;  /* semaphore index in set */
    short   sem_op;          /* operation value */
    short   sem_flg;         /* IPC_NOWAIT, SEM_UNDO */
};
```

Defined in `sys/sys/sem.h:62-66`.

### Undo Structure

```c
struct sem_undo {
    TAILQ_ENTRY(sem_undo) un_entry;  /* global list linkage */
    struct  proc *un_proc;            /* owning process */
    int     un_refs;                  /* reference count */
    short   un_cnt;                   /* active undo entries */
    struct undo {
        short   un_adjval;  /* adjustment value */
        short   un_num;     /* semaphore number */
        int     un_id;      /* semaphore set id */
    } un_ent[1];            /* variable-length array */
};
```

Defined in `sys/kern/sysv_sem.c:49-60`.

## System Limits

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SEMMNI` | 1024 | Max semaphore identifiers |
| `SEMMNS` | 32767 | Max semaphores system-wide |
| `SEMMSL` | SEMMNS | Max semaphores per set |
| `SEMOPM` | 100 | Max operations per semop() |
| `SEMUME` | 25 | Max undo entries per process |
| `SEMVMX` | 32767 | Maximum semaphore value |
| `SEMAEM` | 16384 | Max adjust-on-exit value |

Defined in `sys/kern/sysv_sem.c:65-91`.

## Synchronization

### Global Lock

```c
static struct lock sema_lk;
```

Protects allocation of new semaphore sets and the global `semtot` counter.

### Per-Set Lock

```c
struct semid_pool {
    struct lock lk;  /* exclusive lock for this set */
    ...
};
```

Each semaphore set has its own lock for operations.

### Per-Semaphore Token

Individual semaphores use pool tokens for fine-grained locking:

```c
lwkt_getpooltoken(semptr);
/* modify semptr->semval */
lwkt_relpooltoken(semptr);
```

This allows concurrent operations on different semaphores within the same set.

### Undo List Token

```c
static struct lwkt_token semu_token;
```

Protects the global `semu_list` of undo structures.

## Initialization

`seminit()` runs at `SI_SUB_SYSV_SEM`:

1. Allocates `sema[]` array (SEMMNI entries)
2. Initializes global lock `sema_lk`
3. Initializes per-set locks and marks all slots as unallocated

See `sys/kern/sysv_sem.c:164-181`.

## System Calls

### semget - Create or Access Set

```c
int sys_semget(struct sysmsg *sysmsg, const struct semget_args *uap)
```

**Arguments:** `key`, `nsems`, `semflg`

**Operation:**
1. Check jail capabilities
2. If `key != IPC_PRIVATE`, search for existing set with matching key
3. Validate permissions and nsems count
4. If not found and `IPC_CREAT`, allocate new set:
   - Acquire `sema_lk` exclusive
   - Check system-wide semaphore limit (`semtot + nsems <= semmns`)
   - Find free slot, initialize descriptor
   - Allocate `sem_base` array
   - Set `SEM_ALLOC` flag, increment `semtot`
5. Return unique semid with sequence number

See `sys/kern/sysv_sem.c:573-722`.

### semop - Perform Operations

```c
int sys_semop(struct sysmsg *sysmsg, const struct semop_args *uap)
```

**Arguments:** `semid`, `sops`, `nsops`

**Atomicity:** All operations in a semop() call succeed or fail together.

**Operation:**
1. Copy `sops[]` array from userspace (max `MAX_SOPS` = 5)
2. Acquire set lock shared
3. For each operation:
   - `sem_op < 0`: Decrement if `semval + sem_op >= 0`
   - `sem_op == 0`: Wait until `semval == 0`
   - `sem_op > 0`: Increment unconditionally
4. If any operation blocks:
   - Increment `semncnt` or `semzcnt`
   - Rollback all completed operations
   - If `IPC_NOWAIT`, return `EAGAIN`
   - Release set lock, `tsleep()` on semaphore address
   - On wakeup, reacquire lock and retry from beginning
5. On success, record undo adjustments if `SEM_UNDO` set
6. Update `sempid` for each touched semaphore

**Rollback:** If blocking occurs, previously applied operations are undone
to maintain atomicity. See `sys/kern/sysv_sem.c:883-892`.

See `sys/kern/sysv_sem.c:727-1050`.

### semctl - Control Operations

```c
int sys___semctl(struct sysmsg *sysmsg, const struct __semctl_args *uap)
```

**Arguments:** `semid`, `semnum`, `cmd`, `arg`

**Commands:**

| Command | Description |
|---------|-------------|
| `IPC_STAT` | Copy semid_ds to user buffer |
| `IPC_SET` | Update uid, gid, mode |
| `IPC_RMID` | Remove semaphore set |
| `SEM_STAT` | Like IPC_STAT but semid is array index |
| `GETVAL` | Get single semaphore value |
| `SETVAL` | Set single semaphore value |
| `GETALL` | Get all semaphore values |
| `SETALL` | Set all semaphore values |
| `GETPID` | Get last operation pid |
| `GETNCNT` | Get semncnt (waiters for increment) |
| `GETZCNT` | Get semzcnt (waiters for zero) |

**IPC_RMID Operation:**
1. Decrement global `semtot` by `sem_nsems`
2. Free `sem_base` array
3. Clear `SEM_ALLOC` flag
4. Call `semundo_clear()` to purge undo entries

See `sys/kern/sysv_sem.c:346-568`.

## SEM_UNDO Mechanism

When `SEM_UNDO` flag is set on an operation, the kernel records an
adjustment that will be applied when the process exits.

### Recording Adjustments

`semundo_adjust()` maintains per-process undo entries:

```c
static int semundo_adjust(struct proc *p, int semid, int semnum, int adjval)
```

- Allocates `sem_undo` structure on first use
- Stores negative of the operation value
- Entries are compacted when adjustment becomes zero

See `sys/kern/sysv_sem.c:218-269`.

### Process Exit

`semexit()` is called when a process exits:

1. Iterate through undo entries in reverse order
2. For each entry, apply the recorded adjustment
3. Wake up any waiters on affected semaphores
4. Remove undo structure from global list

See `sys/kern/sysv_sem.c:1058-1163`.

### Clearing Undos on Set Removal

`semundo_clear()` removes undo entries for a deleted semaphore set:

```c
static void semundo_clear(int semid, int semnum)
```

Called by `IPC_RMID` with `semnum = -1` to clear all entries for the set.

See `sys/kern/sysv_sem.c:274-339`.

## Wakeup Optimization

The implementation uses delayed wakeups for efficiency:

```c
wakeup_start_delayed();
/* ... operations that may cause wakeups ... */
wakeup_end_delayed();
```

This batches wakeup signals to reduce context switch overhead.

## Generation Counter

Each semaphore set has a generation counter:

```c
struct semid_pool {
    ...
    long gen;
};
```

Incremented on allocation, used to detect races where a set is destroyed
and recreated while a process sleeps. The sleeping process compares
the generation before and after sleep.

## Jail Support

All system calls check jail capabilities:

```c
if (pr && !PRISON_CAP_ISSET(pr->pr_caps, PRISON_CAP_SYS_SYSVIPC))
    return (ENOSYS);
```

## Sysctl Interface

| Sysctl | Type | Description |
|--------|------|-------------|
| `kern.ipc.semmap` | RW | Entries in semaphore map |
| `kern.ipc.semmni` | RD | Max semaphore identifiers |
| `kern.ipc.semmns` | RD | Max semaphores in system |
| `kern.ipc.semmnu` | RD | Undo structures in system |
| `kern.ipc.semmsl` | RW | Max semaphores per id |
| `kern.ipc.semopm` | RD | Max operations per semop |
| `kern.ipc.semume` | RD | Max undo entries per process |
| `kern.ipc.semusz` | RD | Size of undo structure |
| `kern.ipc.semvmx` | RW | Semaphore maximum value |
| `kern.ipc.semaem` | RW | Adjust on exit max value |

All parameters tunable at boot via loader.

See `sys/kern/sysv_sem.c:119-149`.

## Error Handling

| Error | Condition |
|-------|-----------|
| `ENOSYS` | Jail lacks SYSVIPC capability |
| `EINVAL` | Invalid semid, semnum, or nsems |
| `EEXIST` | `IPC_CREAT|IPC_EXCL` and set exists |
| `ENOENT` | Set not found, no `IPC_CREAT` |
| `ENOSPC` | No free slots or semaphore limit reached |
| `EAGAIN` | `IPC_NOWAIT` and would block |
| `EIDRM` | Set deleted while waiting |
| `EINTR` | Signal received while waiting |
| `EFBIG` | sem_num >= sem_nsems |
| `E2BIG` | Too many operations (nsops > MAX_SOPS) |
