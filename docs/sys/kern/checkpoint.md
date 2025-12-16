# Process Checkpoint/Restart

The DragonFly BSD kernel provides a process checkpoint/restart facility that
allows running processes to be frozen to a file and later resumed. This feature
enables application migration, fault tolerance, and long-running computation
management.

## Overview

Process checkpointing captures the complete state of a running process,
including:

- CPU register state (general-purpose and floating-point registers)
- Virtual memory mappings and contents
- Open file descriptors
- Signal handlers and masks
- Process identity information

The checkpoint file uses the ELF format, leveraging the existing core dump
infrastructure with extensions for restoration.

```
+------------------+     SIGCKPT/sys_checkpoint()     +------------------+
|  Running Process |  --------------------------->    | Checkpoint File  |
|                  |                                  |   (ELF format)   |
+------------------+                                  +------------------+
        ^                                                     |
        |              checkpt -r file.ckpt                   |
        +-----------------------------------------------------+
                          (Restore)
```

## Architecture

### Checkpoint File Format

The checkpoint file is an ELF core file with the following structure:

```
+------------------------+
|     ELF Header         |
|   (e_type = ET_CORE)   |
+------------------------+
|   Program Headers      |
|   (PT_NOTE, PT_LOAD)   |
+------------------------+
|     Notes Section      |
| - NT_PRPSINFO (psinfo) |
| - NT_PRSTATUS (regs)   |
| - NT_FPREGSET (fpregs) |
| - Per-thread state...  |
+------------------------+
|     VM Info Section    |
| - Text/data addresses  |
| - Segment sizes        |
+------------------------+
|   Vnode Headers        |
| - File handles         |
| - Memory mappings      |
+------------------------+
|   Signal Info          |
| - Signal actions       |
| - Signal masks         |
| - Interval timers      |
+------------------------+
|   File Descriptors     |
| - Open file list       |
| - File handles         |
+------------------------+
|   Memory Segments      |
| - Writable data        |
| - Stack contents       |
+------------------------+
```

### Key Data Structures

#### Checkpoint VM Info

```c
/* sys/ckpt.h */
struct ckpt_vminfo {
    segsz_t     cvm_dsize;      /* Data segment size (pages) */
    segsz_t     cvm_tsize;      /* Text segment size (pages) */
    segsz_t     cvm_reserved1[4];
    caddr_t     cvm_daddr;      /* Data segment address */
    caddr_t     cvm_taddr;      /* Text segment address */
    caddr_t     cvm_reserved2[4];
};
```

#### Checkpoint File Info

```c
struct ckpt_fileinfo {
    int         cfi_index;      /* File descriptor number */
    u_int       cfi_flags;      /* Saved f_flag */
    off_t       cfi_offset;     /* Saved f_offset */
    fhandle_t   cfi_fh;         /* File handle for VFS lookup */
    int         cfi_type;       /* File type */
    int         cfi_ckflags;    /* Checkpoint flags */
    int         cfi_reserved[6];
};

#define CKFIF_ISCKPTFD  0x0001  /* This FD is the checkpoint file itself */
```

#### Checkpoint Signal Info

```c
struct ckpt_siginfo {
    int             csi_ckptpisz;   /* Structure size for validation */
    struct sigacts  csi_sigacts;    /* Signal action table */
    struct itimerval csi_itimerval; /* Interval timer */
    int             csi_sigparent;  /* Signal to parent on exit */
    sigset_t        csi_sigmask;    /* Current signal mask */
    int             csi_reserved[6];
};
```

#### Vnode Header

```c
struct vn_hdr {
    fhandle_t   vnh_fh;         /* File handle for mapped file */
    Elf_Phdr    vnh_phdr;       /* Program header for mapping */
    int         vnh_reserved[8];
};
```

## System Call Interface

### sys_checkpoint

The `sys_checkpoint()` system call provides the user interface:

```c
int sys_checkpoint(int type, int fd, pid_t pid, int retval);
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `type` | Operation: `CKPT_FREEZE` or `CKPT_THAW` |
| `fd` | File descriptor for checkpoint file |
| `pid` | Process ID (-1 for current process) |
| `retval` | Return value after restore |

**Operation Types:**

| Type | Value | Description |
|------|-------|-------------|
| `CKPT_FREEZE` | 0x1 | Create checkpoint of current process |
| `CKPT_THAW` | 0x2 | Restore process from checkpoint |
| `CKPT_FREEZEPID` | 0x3 | Checkpoint another process (not implemented) |
| `CKPT_THAWBIN` | 0x4 | Restore with binary replacement (not implemented) |

**Return Value:**

- On freeze: Returns 0 on success
- On thaw: Returns the `retval` parameter passed during restore
- Programs can distinguish between checkpoint creation and restoration by
  checking this return value

### Implementation

Source: `sys/kern/kern_checkpoint.c:715-770`

```c
int 
sys_sys_checkpoint(struct sysmsg *sysmsg,
                   const struct sys_checkpoint_args *uap)
{
    int error = 0;
    struct thread *td = curthread;
    struct proc *p = td->td_proc;
    struct file *fp;

    /* Only certain groups can checkpoint (security) */
    if (ckptgroup >= 0 && groupmember(ckptgroup, td->td_ucred) == 0)
        return (EPERM);

    /* For now only checkpoint current process */
    if (uap->pid != -1 && uap->pid != p->p_pid)
        return (EINVAL);

    get_mplock();

    switch (uap->type) {
    case CKPT_FREEZE:
        fp = NULL;
        if (uap->fd == -1 && uap->pid == (pid_t)-1)
            error = checkpoint_signal_handler(td->td_lwp);
        else if ((fp = holdfp(td, uap->fd, FWRITE)) == NULL)
            error = EBADF;
        else
            error = ckpt_freeze_proc(td->td_lwp, fp);
        if (fp)
            dropfp(td, uap->fd, fp);
        break;
    case CKPT_THAW:
        if (uap->pid != -1) {
            error = EINVAL;
            break;
        }
        if ((fp = holdfp(td, uap->fd, FREAD)) == NULL) {
            error = EBADF;
            break;
        }
        sysmsg->sysmsg_result = uap->retval;
        error = ckpt_thaw_proc(td->td_lwp, fp);
        dropfp(td, uap->fd, fp);
        break;
    default:
        error = EOPNOTSUPP;
        break;
    }
    rel_mplock();
    return error;
}
```

## Checkpoint Signals

DragonFly provides two signals for checkpoint control:

| Signal | Number | Default Action | Description |
|--------|--------|----------------|-------------|
| `SIGCKPT` | 33 | Checkpoint and continue | Process creates checkpoint, continues running |
| `SIGCKPTEXIT` | 34 | Checkpoint and exit | Process creates checkpoint, then terminates |

### Signal Properties

Source: `sys/kern/kern_sig.c:162-163`

```c
SA_CKPT,            /* SIGCKPT */
SA_KILL|SA_CKPT,    /* SIGCKPTEXIT */
```

### Triggering via TTY

Users can trigger checkpoints using the checkpoint character (default: Ctrl+E):

Source: `sys/kern/tty.c:662-665`

```c
if (CCEQ(cc[VCHECKPT], c) && ISSET(lflag, IEXTEN)) {
    if (ISSET(lflag, ISIG))
        pgsignal(tp->t_pgrp, SIGCKPT, 1);
    goto endcase;
}
```

The checkpoint character can be configured using `stty(1)`:

```bash
# View current checkpoint character
stty -a | grep ckpt

# Change checkpoint character
stty ckpt '^T'

# Disable checkpoint character
stty ckpt undef
```

## Freeze Operation

### Process Flow

```
sys_checkpoint(CKPT_FREEZE)
         |
         v
  ckpt_freeze_proc()
         |
         +---> proc_stop(p, SCORE)     # Stop all threads
         |
         +---> Wait for threads to stop
         |
         +---> generic_elf_coredump()  # Write checkpoint
         |
         +---> proc_unstop(p, SCORE)   # Resume threads
         |
         v
     Return to caller
```

### Freeze Implementation

Source: `sys/kern/kern_checkpoint.c:684-710`

```c
static int
ckpt_freeze_proc(struct lwp *lp, struct file *fp)
{
    struct proc *p = lp->lwp_proc;
    rlim_t limit;
    int error;

    lwkt_gettoken(&p->p_token);

    limit = p->p_rlimit[RLIMIT_CORE].rlim_cur;
    if (limit) {
        if (p->p_stat != SCORE) {
            /* Stop all threads in the process */
            proc_stop(p, SCORE);
            
            /* Wait for all threads to stop */
            while (p->p_nstopped < p->p_nthreads - 1)
                tsleep(&p->p_nstopped, 0, "freeze", 1);
            
            /* Generate checkpoint using core dump machinery */
            error = generic_elf_coredump(lp, SIGCKPT, fp, limit);
            
            /* Resume execution */
            proc_unstop(p, SCORE);
        } else {
            error = ERANGE;
        }
    } else {
        error = ERANGE;
    }
    lwkt_reltoken(&p->p_token);
    return error;
}
```

### Signal Handler Checkpoint

When triggered by `SIGCKPT`, the checkpoint goes through a signal handler:

Source: `sys/kern/kern_checkpoint.c:772-828`

```c
int
checkpoint_signal_handler(struct lwp *lp)
{
    struct thread *td = lp->lwp_thread;
    struct proc *p = lp->lwp_proc;
    char *buf;
    struct file *fp;
    struct nlookupdata nd;
    int error;

    chptinuse++;

    /* Security: prevent checkpointing setuid/setgid programs */
    if (sugid_coredump == 0 && (p->p_flags & P_SUGID)) {
        chptinuse--;
        return (EPERM);
    }

    /* Generate checkpoint filename */
    buf = ckpt_expand_name(p->p_comm, td->td_ucred->cr_uid, p->p_pid);
    if (buf == NULL) {
        chptinuse--;
        return (ENOMEM);
    }

    log(LOG_INFO, "pid %d (%s), uid %d: checkpointing to %s\n",
        p->p_pid, p->p_comm,
        (td->td_ucred ? td->td_ucred->cr_uid : -1), buf);

    /* Remove any previous checkpoint file (important for re-checkpointing
     * restored processes - otherwise we corrupt the memory mappings) */
    error = nlookup_init(&nd, buf, UIO_SYSSPACE, 0);
    if (error == 0)
        error = kern_unlink(&nd);
    nlookup_done(&nd);

    /* Create and write checkpoint file */
    error = fp_open(buf, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW, 0600, &fp);
    if (error == 0) {
        error = ckpt_freeze_proc(lp, fp);
        fp_close(fp);
    }
    kfree(buf, M_TEMP);
    chptinuse--;
    return (error);
}
```

## Thaw (Restore) Operation

### Process Flow

```
checkpt -r file.ckpt
         |
         v
sys_checkpoint(CKPT_THAW)
         |
         v
  ckpt_thaw_proc()
         |
         +---> elf_gethdr()        # Read ELF header
         |
         +---> elf_getphdrs()      # Read program headers
         |
         +---> elf_getnotes()      # Restore register state
         |
         +---> elf_gettextvp()     # Restore text mappings
         |
         +---> elf_getsigs()       # Restore signal state
         |
         +---> elf_getfiles()      # Restore file descriptors
         |
         +---> elf_loadphdrs()     # Map memory segments
         |
         +---> Set p_textvp        # Mark as checkpoint-restored
         |
         v
   Resume execution with retval
```

### Thaw Implementation

Source: `sys/kern/kern_checkpoint.c:217-281`

```c
static int
ckpt_thaw_proc(struct lwp *lp, struct file *fp)
{
    struct proc *p = lp->lwp_proc;
    Elf_Phdr *phdr = NULL;
    Elf_Ehdr *ehdr = NULL;
    int error;
    size_t nbyte;

    ehdr = kmalloc(sizeof(Elf_Ehdr), M_TEMP, M_ZERO | M_WAITOK);

    /* Read and validate ELF header */
    if ((error = elf_gethdr(fp, ehdr)) != 0)
        goto done;
    
    nbyte = sizeof(Elf_Phdr) * ehdr->e_phnum;
    phdr = kmalloc(nbyte, M_TEMP, M_WAITOK);

    /* Read program headers */
    if ((error = elf_getphdrs(fp, phdr, nbyte)) != 0)
        goto done;

    /* Restore register state from notes section */
    if ((error = elf_getnotes(lp, fp, phdr->p_filesz)) != 0)
        goto done;

    /* Restore text segment mappings */
    if ((error = elf_gettextvp(p, fp)) != 0)
        goto done;

    /* Restore signal handlers and masks */
    if ((error = elf_getsigs(lp, fp)) != 0)
        goto done;

    /* Restore file descriptors */
    if ((error = elf_getfiles(lp, fp)) != 0)
        goto done;

    /* Map memory segments from checkpoint file */
    error = elf_loadphdrs(fp, phdr, ehdr->e_phnum);

    /* Mark process as checkpoint-restored to handle re-checkpointing */
    if (error == 0 && fp->f_data && fp->f_type == DTYPE_VNODE) {
        if (p->p_textvp)
            vrele(p->p_textvp);
        p->p_textvp = (struct vnode *)fp->f_data;
        vsetflags(p->p_textvp, VCKPT);
        vref(p->p_textvp);
    }
done:
    if (ehdr)
        kfree(ehdr, M_TEMP);
    if (phdr)
        kfree(phdr, M_TEMP);
    return error;
}
```

### Register State Restoration

Source: `sys/kern/kern_checkpoint.c:283-311`

```c
static int
elf_loadnotes(struct lwp *lp, prpsinfo_t *psinfo, prstatus_t *status,
           prfpregset_t *fpregset)
{
    struct proc *p = lp->lwp_proc;
    int error;

    /* Validate note structures */
    if (status->pr_version != PRSTATUS_VERSION ||
        status->pr_statussz != sizeof(prstatus_t) ||
        status->pr_gregsetsz != sizeof(gregset_t) ||
        status->pr_fpregsetsz != sizeof(fpregset_t) ||
        psinfo->pr_version != PRPSINFO_VERSION ||
        psinfo->pr_psinfosz != sizeof(prpsinfo_t)) {
        return EINVAL;
    }

    /* Restore general-purpose registers */
    if ((error = set_regs(lp, &status->pr_reg)) != 0)
        return error;

    /* Restore floating-point registers */
    error = set_fpregs(lp, fpregset);

    /* Restore process name */
    strlcpy(p->p_comm, psinfo->pr_fname, sizeof(p->p_comm));

    return error;
}
```

### File Descriptor Restoration

Source: `sys/kern/kern_checkpoint.c:581-682`

The file restoration process:

1. Closes all file descriptors >= 3 (inherited from `checkpt` utility)
2. Iterates through saved file descriptors
3. Uses file handles (`fhandle_t`) to locate vnodes via VFS
4. Reopens files with saved flags and offsets
5. Special handling for checkpoint file descriptor itself

```c
/* If this FD is the checkpoint file, reuse current fp */
if (cfi->cfi_ckflags & CKFIF_ISCKPTFD) {
    fhold(fp);
    tempfp = fp;
    error = 0;
} else {
    /* Convert file handle to vnode and open */
    error = ckpt_fhtovp(&cfi->cfi_fh, &vp);
    if (error == 0) {
        error = fp_vpopen(vp, OFLAGS(cfi->cfi_flags), &tempfp);
        if (error)
            vput(vp);
    }
}
```

### Memory Segment Restoration

Memory segments are mapped directly from the checkpoint file:

Source: `sys/kern/kern_checkpoint.c:398-427`

```c
static int
mmap_phdr(struct file *fp, Elf_Phdr *phdr)
{
    int error;
    size_t len;
    int prot;
    void *addr;
    int flags;
    off_t pos;

    pos = phdr->p_offset;
    len = phdr->p_filesz;
    addr = (void *)phdr->p_vaddr;
    flags = MAP_FIXED | MAP_NOSYNC | MAP_PRIVATE;
    
    prot = 0;
    if (phdr->p_flags & PF_R)
        prot |= PROT_READ;
    if (phdr->p_flags & PF_W)
        prot |= PROT_WRITE;
    if (phdr->p_flags & PF_X)
        prot |= PROT_EXEC;
    
    error = fp_mmap(addr, len, prot, flags, fp, pos, &addr);
    return error;
}
```

## Configuration

### Sysctl Variables

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kern.ckptgroup` | 0 (wheel) | Group allowed to checkpoint (-1 = any) |
| `kern.ckptfile` | `%N.ckpt` | Checkpoint filename template |

### Filename Template

The checkpoint filename supports format specifiers:

| Specifier | Expansion |
|-----------|-----------|
| `%N` | Process name (comm) |
| `%P` | Process ID |
| `%U` | User ID |
| `%%` | Literal `%` |

Examples:
```bash
# Default: creates "programname.ckpt" in current directory
sysctl kern.ckptfile="%N.ckpt"

# Store by user and process name
sysctl kern.ckptfile="/var/checkpoints/%U/%N-%P.ckpt"

# Store all checkpoints centrally
sysctl kern.ckptfile="/cores/%N.ckpt"
```

## Userland Interface

### checkpt Utility

The `checkpt(1)` utility restores checkpointed processes:

```bash
# Restore a checkpoint
checkpt -r myprogram.ckpt
```

Source: `usr.bin/checkpt/checkpt.c`

```c
int main(int ac, char **av)
{
    int fd;
    int error;
    const char *filename = NULL;

    /* Parse arguments */
    while ((ch = getopt(ac, av, "r:")) != -1) {
        switch(ch) {
        case 'r':
            filename = optarg;
            break;
        }
    }

    fd = open(filename, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "unable to open %s\n", filename);
        exit(1);
    }

    /* Restore process - on success, does not return */
    error = sys_checkpoint(CKPT_THAW, fd, -1, 1);
    
    /* Only reach here on error */
    fprintf(stderr, "thaw failed error %d %s\n", errno, strerror(errno));
    return(5);
}
```

### Creating Checkpoints

Programs can be checkpointed in several ways:

1. **Keyboard**: Press Ctrl+E (configurable via `stty`)
2. **Signal**: Send `SIGCKPT` or `SIGCKPTEXIT`
3. **Programmatic**: Call `sys_checkpoint(CKPT_FREEZE, fd, -1, 0)`

### Application-Aware Checkpointing

Programs can actively support checkpointing:

```c
#include <sys/checkpoint.h>
#include <signal.h>

volatile sig_atomic_t checkpoint_requested = 0;

void sigckpt_handler(int sig) {
    checkpoint_requested = 1;
}

int main() {
    int fd, result;
    
    /* Install checkpoint signal handler */
    signal(SIGCKPT, sigckpt_handler);
    
    while (1) {
        /* Application work... */
        
        if (checkpoint_requested) {
            checkpoint_requested = 0;
            
            /* Clean up transient state */
            close_network_connections();
            flush_caches();
            
            /* Create checkpoint */
            fd = open("myapp.ckpt", O_WRONLY|O_CREAT|O_TRUNC, 0600);
            result = sys_checkpoint(CKPT_FREEZE, fd, -1, 42);
            close(fd);
            
            if (result == 42) {
                /* We were just restored */
                reopen_network_connections();
                printf("Resumed from checkpoint\n");
            } else {
                /* Checkpoint created, continue running */
                printf("Checkpoint created\n");
            }
        }
    }
}
```

## Limitations

### What Can Be Checkpointed

- Regular processes with normal file descriptors
- Memory-mapped regular files
- Signal handlers and masks
- CPU register state (general and FP)
- Process credentials and identity

### What Cannot Be Checkpointed

| Resource | Reason |
|----------|--------|
| Network sockets | Connection state is external |
| Pipes | No persistent backing |
| Device files | Hardware state cannot be saved |
| Shared memory | Cross-process state issues |
| Semaphores/mutexes | Synchronization state lost |
| Setuid/setgid programs | Security restriction |

### File System Requirements

- Files must be accessible by file handle after restore
- File system must support `VFS_FHTOVP` operation
- Files should not be modified between checkpoint and restore

### Thread Limitations

The current implementation has limited multi-thread support:

```c
#define CKPT_MAXTHREADS 256

/* Thread state is saved, but restoration may be incomplete */
nthreads = (notesz - sizeof(prpsinfo_t)) /
           (sizeof(prstatus_t) + sizeof(prfpregset_t));
```

## Security Considerations

### Group Restriction

By default, only the wheel group can checkpoint:

```c
static int ckptgroup = 0;  /* wheel only */
SYSCTL_INT(_kern, OID_AUTO, ckptgroup, CTLFLAG_RW, &ckptgroup, 0, "");

/* In sys_sys_checkpoint(): */
if (ckptgroup >= 0 && groupmember(ckptgroup, td->td_ucred) == 0)
    return (EPERM);
```

### Setuid/Setgid Protection

Checkpointing privileged processes is prevented:

```c
if (sugid_coredump == 0 && (p->p_flags & P_SUGID)) {
    return (EPERM);
}
```

### Checkpoint File Permissions

Checkpoint files are created with restrictive permissions:

```c
error = fp_open(buf, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW, 0600, &fp);
```

## Re-Checkpointing

A checkpoint-restored process can be checkpointed again. Special handling
ensures the new checkpoint contains actual memory contents rather than
references to the old checkpoint file:

```c
/* Mark the vnode so future checkpoints copy data instead of recording
 * vnode references to the checkpoint file */
if (error == 0 && fp->f_data && fp->f_type == DTYPE_VNODE) {
    p->p_textvp = (struct vnode *)fp->f_data;
    vsetflags(p->p_textvp, VCKPT);  /* Mark as checkpoint source */
    vref(p->p_textvp);
}
```

When checkpointing a restored process, the old checkpoint file is removed
first to avoid corrupting the running process's memory mappings:

```c
/* Remove previous checkpoint before creating new one */
error = nlookup_init(&nd, buf, UIO_SYSSPACE, 0);
if (error == 0)
    error = kern_unlink(&nd);
nlookup_done(&nd);
```

## Related Documentation

- [Processes and Threads](processes.md) - Process state management
- [Signals](signals.md) - Signal delivery and handling
- [Virtual Memory](../vm/index.md) - Memory mapping operations
- [VFS Operations](vfs/vfs-operations.md) - File handle operations

## Source Files

| File | Description |
|------|-------------|
| `sys/kern/kern_checkpoint.c` | Checkpoint/restart implementation |
| `sys/sys/checkpoint.h` | User interface definitions |
| `sys/sys/ckpt.h` | Kernel structures |
| `sys/kern/imgact_elf.c` | ELF core dump generation |
| `sys/kern/kern_sig.c` | Signal handling integration |
| `sys/kern/tty.c` | TTY checkpoint character handling |
| `usr.bin/checkpt/checkpt.c` | Restore utility |
