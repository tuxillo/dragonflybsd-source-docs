# Pipes

Pipes provide unidirectional byte streams for inter-process communication. DragonFly's implementation (`sys/kern/sys_pipe.c`) replaces the traditional socket-based approach with a high-performance VM-backed design featuring per-CPU caching and busy-wait optimization.

## Data Structures

### Pipe Buffer

Each direction of a pipe uses a `struct pipebuf` (`sys/sys/pipe.h:53`):

```c
struct pipebuf {
    struct {
        struct lwkt_token rlock;
        size_t      rindex;     /* current read index (FIFO) */
        int32_t     rip;        /* read-in-progress flag */
        struct timespec atime;  /* time of last access */
    } __cachealign;
    struct {
        struct lwkt_token wlock;
        size_t      windex;     /* current write index (FIFO) */
        int32_t     wip;        /* write-in-progress flag */
        struct timespec mtime;  /* time of last modify */
    } __cachealign;
    size_t      size;           /* size of buffer */
    caddr_t     buffer;         /* kva of buffer */
    struct vm_object *object;   /* VM object containing buffer */
    struct kqinfo   kq;         /* for select/poll/kq */
    struct sigio    *sigio;     /* async I/O info */
    uint32_t    state;          /* pipe status flags */
    int         lticks;         /* timestamp optimization */
} __cachealign;
```

The structure uses `__cachealign` to separate read and write fields onto different cache lines, reducing false sharing between reader and writer.

### Pipe Structure

The main `struct pipe` (`sys/sys/pipe.h:91`) contains two buffers for full-duplex communication:

```c
struct pipe {
    struct pipebuf  bufferA;    /* data storage */
    struct pipebuf  bufferB;    /* data storage */
    struct timespec ctime;      /* creation time */
    struct pipe     *next;      /* per-CPU cache linkage */
    uint32_t        open_count; /* reference count */
    uint64_t        inum;       /* inode number */
} __cachealign;
```

Each file descriptor identifies which buffer it reads from using the low bit of `fp->f_data`: bit 0 clear reads from `bufferA`, bit 1 set reads from `bufferB`.

### State Flags

Buffer state tracked in `pipebuf.state` (`sys/sys/pipe.h:80-85`):

| Flag | Value | Description |
|------|-------|-------------|
| `PIPE_ASYNC` | 0x0004 | Async I/O enabled (SIGIO) |
| `PIPE_WANTR` | 0x0008 | Reader is sleeping |
| `PIPE_WANTW` | 0x0010 | Writer is sleeping |
| `PIPE_REOF` | 0x0040 | Read EOF (peer closed write) |
| `PIPE_WEOF` | 0x0080 | Write EOF (shutdown) |
| `PIPE_CLOSED` | 0x1000 | This side fully closed |

## System Calls

### pipe() and pipe2()

`sys_pipe()` and `sys_pipe2()` (`sys_pipe.c:262-274`) create a pipe pair:

```c
int sys_pipe(struct sysmsg *sysmsg, const struct pipe_args *uap)
{
    return kern_pipe(sysmsg->sysmsg_fds, 0);
}

int sys_pipe2(struct sysmsg *sysmsg, const struct pipe2_args *uap)
{
    if ((uap->flags & ~(O_CLOEXEC | O_CLOFORK | O_NONBLOCK)) != 0)
        return (EINVAL);
    return kern_pipe(sysmsg->sysmsg_fds, uap->flags);
}
```

`pipe2()` accepts flags: `O_CLOEXEC` (close on exec), `O_CLOFORK` (close on fork), and `O_NONBLOCK`.

### kern_pipe()

The core creation logic (`sys_pipe.c:276-349`):

1. Allocates a `struct pipe` via `pipe_create()`
2. Allocates two file descriptors with `falloc()`
3. Configures read-side fd (bit 0 = 0) and write-side fd (bit 0 = 1)
4. Sets `f_ops` to `pipeops` for both
5. Activates descriptors with `fsetfd()`

Both file descriptors have `FREAD | FWRITE` flags set, though traditionally one is the read end and one is the write end.

## VM-Backed Buffers

### Buffer Allocation

`pipespace()` (`sys_pipe.c:359-405`) allocates kernel virtual address space backed by a VM object:

```c
static int
pipespace(struct pipe *pipe, struct pipebuf *pb, size_t size)
{
    size = (size + PAGE_MASK) & ~(size_t)PAGE_MASK;
    if (size < 16384)
        size = 16384;
    if (size > 1024*1024)
        size = 1024*1024;

    npages = round_page(size) / PAGE_SIZE;
    
    if (object == NULL || object->size != npages) {
        object = vm_object_allocate(OBJT_DEFAULT, npages);
        buffer = (caddr_t)vm_map_min(kernel_map);
        
        error = vm_map_find(kernel_map, object, NULL,
                0, (vm_offset_t *)&buffer, size,
                PAGE_SIZE, TRUE,
                VM_MAPTYPE_NORMAL, VM_SUBSYS_PIPE,
                VM_PROT_ALL, VM_PROT_ALL, 0);
        /* ... */
    }
    pb->rindex = 0;
    pb->windex = 0;
    return (0);
}
```

Key points:
- Buffer size clamped between 16KB and 1MB
- Uses `OBJT_DEFAULT` VM objects (pageable, swap-backed)
- Each buffer has an independent `vm_object` for performance
- Default size controlled by sysctl `kern.pipe.size` (32KB)

## Per-CPU Pipe Cache

### Cache Design

To reduce allocation overhead, pipes are cached per-CPU (`sys_pipe.c:111-118`):

```c
#define PIPEQ_MAX_CACHE 16      /* per-cpu pipe structure cache */

static int pipe_maxcache = PIPEQ_MAX_CACHE;
static struct pipegdlock *pipe_gdlocks;
```

The cache lives in `globaldata_t`:
- `gd->gd_pipeq` - linked list of cached pipes
- `gd->gd_pipeqcount` - number of cached pipes

### Cache Initialization

`pipeinit()` (`sys_pipe.c:148-177`) scales the cache based on system memory:

```c
static void
pipeinit(void *dummy)
{
    size_t mbytes = kmem_lim_size();

    if (pipe_maxcache == PIPEQ_MAX_CACHE) {
        if (mbytes >= 7 * 1024)
            pipe_maxcache *= 2;
        if (mbytes >= 15 * 1024)
            pipe_maxcache *= 2;
    }

    /* Reduce cache on systems with many CPUs */
    if (ncpus > 64) {
        pipe_maxcache = pipe_maxcache * 64 / ncpus;
        if (pipe_maxcache < PIPEQ_MAX_CACHE)
            pipe_maxcache = PIPEQ_MAX_CACHE;
    }
    /* ... */
}
```

### Allocation from Cache

`pipe_create()` (`sys_pipe.c:414-448`) checks the per-CPU cache first:

```c
static int
pipe_create(struct pipe **pipep)
{
    globaldata_t gd = mycpu;
    struct pipe *pipe;

    if ((pipe = gd->gd_pipeq) != NULL) {
        gd->gd_pipeq = pipe->next;
        --gd->gd_pipeqcount;
        pipe->next = NULL;
    } else {
        pipe = kmalloc(sizeof(*pipe), M_PIPE, M_WAITOK | M_ZERO);
        pipe->inum = gd->gd_anoninum++ * ncpus + gd->gd_cpuid + 2;
        lwkt_token_init(&pipe->bufferA.rlock, "piper");
        lwkt_token_init(&pipe->bufferA.wlock, "pipew");
        lwkt_token_init(&pipe->bufferB.rlock, "piper");
        lwkt_token_init(&pipe->bufferB.wlock, "pipew");
    }
    /* ... allocate buffer space ... */
}
```

The inode number generation (`gd->gd_anoninum++ * ncpus + gd->gd_cpuid + 2`) ensures unique inums across CPUs without synchronization.

### Return to Cache

When both ends close, `pipeclose()` (`sys_pipe.c:1272-1287`) returns the pipe to the cache:

```c
if (atomic_fetchadd_int(&pipe->open_count, -1) == 1) {
    gd = mycpu;
    if (gd->gd_pipeqcount >= pipe_maxcache) {
        mtx_lock(&pipe_gdlocks[gd->gd_cpuid].mtx);
        pipe_free_kmem(rpb);
        pipe_free_kmem(wpb);
        mtx_unlock(&pipe_gdlocks[gd->gd_cpuid].mtx);
        kfree(pipe, M_PIPE);
    } else {
        rpb->state = 0;
        wpb->state = 0;
        pipe->next = gd->gd_pipeq;
        gd->gd_pipeq = pipe;
        ++gd->gd_pipeqcount;
    }
}
```

The per-CPU mutex (`pipe_gdlocks`) serializes access to `kernel_map` during bulk teardown scenarios (e.g., mass process termination).

## Read Operation

### pipe_read()

`pipe_read()` (`sys_pipe.c:453-698`) implements reading:

1. **Buffer selection**: Determines read buffer based on `fp->f_data` bit 0
2. **Quick NBIO check**: Returns `EAGAIN` early if non-blocking and buffer empty
3. **Serialization**: Acquires `rlock` token and calls `pipe_start_uio()` to serialize against other readers
4. **Copy loop**: Reads available data via `uiomove()`

Key features of the read loop:

```c
while (uio->uio_resid) {
    size = rpb->windex - rpb->rindex;
    cpu_lfence();  /* memory barrier before reading buffer */
    
    if (size) {
        rindex = rpb->rindex & (rpb->size - 1);
        nsize = szmin(size, uio->uio_resid);
        
        /* Limit to half buffer to avoid ping-pong */
        if (nsize > (rpb->size >> 1))
            nsize = rpb->size >> 1;
            
        error = uiomove(&rpb->buffer[rindex], nsize, uio);
        rpb->rindex += nsize;
        
        /* Wake writer if buffer less than half full */
        if (size - nsize <= (rpb->size >> 1))
            pipesignal(rpb, PIPE_WANTW);
        continue;
    }
    /* ... blocking logic ... */
}
```

The buffer uses power-of-2 sizing, so `rindex & (size - 1)` computes the circular buffer offset efficiently.

### Busy-Wait Optimization

Before sleeping, the reader busy-waits for a configurable period (`sys_pipe.c:599-615`):

```c
#ifdef _RDTSC_SUPPORTED_
if (pipe_delay) {
    int64_t tsc_target;
    int good = 0;

    tsc_target = tsc_get_target(pipe_delay);
    while (tsc_test_target(tsc_target) == 0) {
        cpu_lfence();
        if (rpb->windex != rpb->rindex) {
            good = 1;
            break;
        }
        cpu_pause();
    }
    if (good)
        continue;
}
#endif
```

The `pipe_delay` sysctl (default 4000ns = 4us) trades CPU cycles for reduced IPI/wakeup latency. This is effective for synchronous producer-consumer patterns.

## Write Operation

### pipe_write()

`pipe_write()` (`sys_pipe.c:700-987`) mirrors the read path:

1. **Buffer selection**: Writes to the peer's read buffer
2. **EOF check**: Returns `EPIPE` if `PIPE_WEOF` is set
3. **Atomicity**: Writes <= `PIPE_BUF` (512 bytes) are atomic

```c
while (uio->uio_resid) {
    space = wpb->size - (wpb->windex - wpb->rindex);
    
    /* Writes <= PIPE_BUF must be atomic */
    if ((space < uio->uio_resid) && (orig_resid <= PIPE_BUF))
        space = 0;
    
    if (space > 0) {
        /* Limit to half buffer for pipelining */
        if (space > (wpb->size >> 1))
            space = (wpb->size >> 1);
            
        /* Handle wraparound */
        windex = wpb->windex & (wpb->size - 1);
        segsize = wpb->size - windex;
        if (segsize > space)
            segsize = space;
            
        error = uiomove(&wpb->buffer[windex], segsize, uio);
        if (error == 0 && segsize < space) {
            segsize = space - segsize;
            error = uiomove(&wpb->buffer[0], segsize, uio);
        }
        
        cpu_sfence();  /* ensure data visible before windex update */
        wpb->windex += space;
        pipesignal(wpb, PIPE_WANTR);
        continue;
    }
    /* ... blocking logic with busy-wait ... */
}
```

The store fence (`cpu_sfence()`) ensures buffer contents are visible to readers before `windex` is updated.

## Synchronization

### Token-Based Locking

Each buffer has separate read and write tokens:
- `rlock` - held during reads, protects `rindex`
- `wlock` - held during writes, protects `windex`

This allows concurrent read and write operations on the same buffer.

### UIO Serialization

The `rip` and `wip` fields serialize multiple concurrent reads or writes (`sys_pipe.c:228-253`):

```c
static __inline int
pipe_start_uio(int *ipp)
{
    int error;
    while (*ipp) {
        *ipp = -1;  /* mark as contended */
        error = tsleep(ipp, PCATCH, "pipexx", 0);
        if (error)
            return (error);
    }
    *ipp = 1;  /* mark as in-progress */
    return (0);
}

static __inline void
pipe_end_uio(int *ipp)
{
    if (*ipp < 0) {
        *ipp = 0;
        wakeup(ipp);  /* wake contending thread */
    } else {
        *ipp = 0;
    }
}
```

### Signal and Wakeup

`pipesignal()` (`sys_pipe.c:188-203`) atomically clears wait flags and wakes sleepers:

```c
static __inline void
pipesignal(struct pipebuf *pb, uint32_t flags)
{
    uint32_t oflags, nflags;
    
    for (;;) {
        oflags = pb->state;
        cpu_ccfence();
        nflags = oflags & ~flags;
        if (atomic_cmpset_int(&pb->state, oflags, nflags))
            break;
    }
    if (oflags & flags)
        wakeup(pb);
}
```

## Shutdown and Close

### pipe_shutdown()

`pipe_shutdown()` (`sys_pipe.c:1113-1183`) implements partial close semantics:

```c
switch(how) {
case SHUT_RDWR:
case SHUT_RD:
    atomic_set_int(&rpb->state, PIPE_REOF | PIPE_WEOF);
    /* wake waiters */
    if (how == SHUT_RD)
        break;
    /* fall through */
case SHUT_WR:
    atomic_set_int(&wpb->state, PIPE_REOF | PIPE_WEOF);
    /* wake waiters */
    break;
}
```

This requires all four tokens (both rlock and wlock for both buffers) since it modifies state on both sides.

### pipeclose()

`pipeclose()` (`sys_pipe.c:1203-1288`) handles final cleanup:

1. Sets `PIPE_CLOSED | PIPE_REOF | PIPE_WEOF` on own buffer
2. Sets `PIPE_REOF | PIPE_WEOF` on peer buffer
3. Wakes all waiters on both sides
4. When `open_count` reaches 0, returns to cache or frees

## File Operations

The `pipeops` structure (`sys_pipe.c:89-98`):

```c
static struct fileops pipeops = {
    .fo_read = pipe_read, 
    .fo_write = pipe_write,
    .fo_ioctl = pipe_ioctl,
    .fo_kqfilter = pipe_kqfilter,
    .fo_stat = pipe_stat,
    .fo_close = pipe_close,
    .fo_shutdown = pipe_shutdown,
    .fo_seek = badfo_seek
};
```

### Supported ioctls

`pipe_ioctl()` (`sys_pipe.c:992-1048`) supports:

| ioctl | Description |
|-------|-------------|
| `FIOASYNC` | Enable/disable async I/O (SIGIO) |
| `FIONREAD` | Return bytes available for read |
| `FIOSETOWN` | Set owner for SIGIO |
| `FIOGETOWN` | Get owner for SIGIO |
| `TIOCSPGRP` | Set process group (deprecated) |
| `TIOCGPGRP` | Get process group (deprecated) |

### kqueue Support

`pipe_kqfilter()` (`sys_pipe.c:1290-1325`) supports `EVFILT_READ` and `EVFILT_WRITE`:

```c
switch (kn->kn_filter) {
case EVFILT_READ:
    kn->kn_fop = &pipe_rfiltops;
    break;
case EVFILT_WRITE:
    kn->kn_fop = &pipe_wfiltops;
    break;
}
knote_insert(&rpb->kq.ki_note, kn);
```

The filter operations are marked `FILTEROP_MPSAFE` and rely on the knote's `KN_PROCESSING` flag for synchronization rather than pipe tokens.

## Sysctl Tunables

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kern.pipe.size` | 32768 | Default buffer size for new pipes |
| `kern.pipe.maxcache` | 16-64 | Per-CPU cache size (scaled by memory) |
| `kern.pipe.delay` | 4000 | Busy-wait time in nanoseconds |

## Source Reference

| File | Description |
|------|-------------|
| `sys/kern/sys_pipe.c` | Pipe implementation |
| `sys/sys/pipe.h` | Pipe structures and flags |
