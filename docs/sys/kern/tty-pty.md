# Pseudo-Terminals (PTY)

Pseudo-terminals provide a bidirectional communication channel that emulates
a hardware terminal. They consist of a master/slave pair where the master side
(ptc) is used by programs like terminal emulators and SSH daemons, while the
slave side (pts) appears as a regular terminal device to shell processes.

For background on pseudo-terminals and their role in terminal emulation, see
[Wikipedia: Pseudoterminal](https://en.wikipedia.org/wiki/Pseudoterminal).

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `sys/kern/tty_pty.c` | 1,355 | Pseudo-terminal driver implementation |

## Architecture Overview

```
  Terminal Emulator (xterm, ssh, etc.)
         |
    open("/dev/ptmx")
         |
         v
  +------------------+
  | PTY Master (ptc) |  /dev/ptm/N or /dev/ptyXX
  |   ptcread()      |  Reads slave's output
  |   ptcwrite()     |  Writes to slave's input
  +------------------+
         |
    Internal queues (t_outq, t_rawq, t_canq)
         |
         v
  +------------------+
  | PTY Slave (pts)  |  /dev/pts/N or /dev/ttyXX
  |   ptsread()      |  Reads processed input
  |   ptswrite()     |  Writes to output queue
  +------------------+
         |
    Line discipline processing
         |
         v
  Shell / Application Process
```

## Data Flow

### Master to Slave (Input)

```
ptcwrite()                 Master writes data
    |
    v
l_rint() for each char     Line discipline input processing
    |
    +-- Canonical mode --> t_rawq --> t_canq (on line completion)
    |
    +-- Raw mode -------> t_rawq
    |
    v
ptsread()                  Slave reads processed data
```

### Slave to Master (Output)

```
ptswrite()                 Slave writes data
    |
    v
l_write()                  Line discipline output processing
    |
    v
ttyoutput()                Output post-processing (OPOST)
    |
    v
t_outq                     Output queue
    |
    v
ptsstart()                 Start output (wakes master)
    |
    v
ptcread()                  Master reads slave's output
```

## Data Structures

### Per-PTY State

Each pseudo-terminal pair maintains state in `struct pt_ioctl` (`tty_pty.c:142`):

```c
struct pt_ioctl {
    int         pt_flags;       /* State flags (PF_*) */
    int         pt_refs;        /* Reference count */
    int         pt_uminor;      /* Unit minor number */
    struct kqinfo pt_kqr;       /* kqueue read info */
    struct kqinfo pt_kqw;       /* kqueue write info */
    u_char      pt_send;        /* Packet mode events to send */
    u_char      pt_ucntl;       /* User control mode byte */
    struct tty  pt_tty;         /* Embedded tty structure */
    cdev_t      devs;           /* Slave device */
    cdev_t      devc;           /* Master device */
    struct prison *pt_prison;   /* Jail association */
};
```

### PTY State Flags

Control flags in `pt_flags` (`tty_pty.c:157`):

```c
/* Master-side operational modes */
#define PF_PKT          0x0008  /* Packet mode enabled */
#define PF_STOPPED      0x0010  /* Output stopped by user */
#define PF_REMOTE       0x0020  /* Remote mode (flow-controlled input) */
#define PF_NOSTOP       0x0040  /* Don't send STOP/START packets */
#define PF_UCNTL        0x0080  /* User control mode */

#define PF_PTCSTATEMASK 0x00FF  /* Mask for ptc operational state */

/* Open state tracking */
#define PF_UNIX98       0x0100  /* Unix98 PTY (dynamically allocated) */
#define PF_SOPEN        0x0200  /* Slave side is open */
#define PF_MOPEN        0x0400  /* Master side is open */
#define PF_SCLOSED      0x0800  /* Slave was opened then closed */
#define PF_TERMINATED   0x8000  /* PTY is being destroyed */
```

## Device Naming

DragonFly supports two PTY naming schemes:

### BSD-Style PTYs (Legacy)

Pre-allocated at boot, limited to 256 pairs:

| Device | Pattern | Example |
|--------|---------|---------|
| Master | `/dev/pty[pqrsPQRS][0-9a-v]` | `/dev/ptyp0` |
| Slave | `/dev/tty[pqrsPQRS][0-9a-v]` | `/dev/ttyp0` |

### Unix98-Style PTYs

Dynamically allocated via `/dev/ptmx`, up to 1000 pairs:

| Device | Pattern | Example |
|--------|---------|---------|
| Clone device | `/dev/ptmx` | (open to allocate) |
| Master | `/dev/ptm/N` | `/dev/ptm/0` |
| Slave | `/dev/pts/N` | `/dev/pts/0` |

## PTY Allocation

### Unix98 Allocation

Opening `/dev/ptmx` triggers the clone handler (`tty_pty.c:215`):

```c
static int
ptyclone(struct dev_clone_args *ap)
{
    int unit;
    struct pt_ioctl *pti;

    /* Allocate unit from clone bitmap (max MAXPTYS=1000) */
    unit = devfs_clone_bitmap_get(&DEVFS_CLONE_BITMAP(pty), MAXPTYS);
    if (unit < 0) {
        ap->a_dev = NULL;
        return 1;                   /* No PTYs available */
    }

    /* Allocate or reuse pti structure */
    if ((pti = ptis[unit]) == NULL) {
        lwkt_gettoken(&tty_token);
        pti = kmalloc(sizeof(*pti), M_PTY, M_WAITOK | M_ZERO);
        if (ptis[unit] == NULL) {
            ptis[unit] = pti;
            ttyinit(&pti->pt_tty);
        } else {
            kfree(pti, M_PTY);      /* Race: another thread allocated */
        }
        lwkt_reltoken(&tty_token);
    }

    /* Create device nodes */
    pti->devc = make_only_dev(&ptc98_ops, unit,
                              ap->a_cred->cr_ruid,
                              0, 0600, "ptm/%d", unit);
    pti->devs = make_dev(&pts98_ops, unit,
                         ap->a_cred->cr_ruid,
                         GID_TTY, 0620, "pts/%d", unit);

    /* Initialize PTY state */
    pti->pt_tty.t_dev = pti->devs;
    pti->pt_flags = PF_UNIX98;
    pti->pt_uminor = unit;
    pti->devs->si_drv1 = pti->devc->si_drv1 = pti;
    pti->devs->si_tty = pti->devc->si_tty = &pti->pt_tty;
    ttyregister(&pti->pt_tty);

    ap->a_dev = pti->devc;          /* Return master device */
    return 0;
}
```

### BSD-Style Initialization

BSD PTYs are pre-created at boot (`tty_pty.c:186`):

```c
static void
ptyinit(int n)
{
    cdev_t devs, devc;
    char *names = "pqrsPQRS";       /* 8 groups */
    struct pt_ioctl *pti;

    if (n & ~0xff)
        return;                     /* Only 256 supported */

    pti = kmalloc(sizeof(*pti), M_PTY, M_WAITOK | M_ZERO);
    
    /* Create /dev/ttyXX (slave) */
    pti->devs = devs = make_dev(&pts_ops, n, 0, 0, 0666,
                                "tty%c%c",
                                names[n / 32], hex2ascii(n % 32));
    
    /* Create /dev/ptyXX (master) */
    pti->devc = devc = make_dev(&ptc_ops, n, 0, 0, 0666,
                                "pty%c%c",
                                names[n / 32], hex2ascii(n % 32));

    pti->pt_tty.t_dev = devs;
    pti->pt_uminor = n;
    devs->si_drv1 = devc->si_drv1 = pti;
    devs->si_tty = devc->si_tty = &pti->pt_tty;
    ttyinit(&pti->pt_tty);
    ttyregister(&pti->pt_tty);
}
```

## Master Side Operations

### Opening the Master

`ptcopen()` (`tty_pty.c:610`) initializes the master side:

```c
static int
ptcopen(struct dev_open_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp;
    struct pt_ioctl *pti;

    pti = dev->si_drv1;
    if (pti == NULL)
        return(ENXIO);

    lwkt_gettoken(&pti->pt_tty.t_token);
    if (pti_hold(pti)) {            /* Check for termination race */
        lwkt_reltoken(&pti->pt_tty.t_token);
        return(ENXIO);
    }
    
    /* Check jail association */
    if (pti->pt_prison && pti->pt_prison != ap->a_cred->cr_prison) {
        pti_done(pti);
        lwkt_reltoken(&pti->pt_tty.t_token);
        return(EBUSY);
    }
    
    tp = dev->si_tty;
    lwkt_gettoken(&tp->t_token);
    
    /* Only one master open at a time */
    if (tp->t_oproc) {
        pti_done(pti);
        lwkt_reltoken(&tp->t_token);
        lwkt_reltoken(&pti->pt_tty.t_token);
        return (EIO);
    }

    /* Clear zombie state if slave not open */
    if ((pti->pt_flags & PF_SOPEN) == 0)
        tp->t_state &= ~TS_ZOMBIE;

    /* Install callbacks */
    tp->t_oproc = ptsstart;         /* Output start routine */
    tp->t_stop = ptsstop;           /* Output stop routine */
    tp->t_unhold = ptsunhold;       /* Reference release callback */

    /* Carrier on - wakes slave if waiting */
    (void)(*linesw[tp->t_line].l_modem)(tp, 1);

    /* Initialize master state */
    tp->t_lflag &= ~EXTPROC;
    pti->pt_prison = ap->a_cred->cr_prison;
    pti->pt_flags &= ~PF_PTCSTATEMASK;
    pti->pt_send = 0;
    pti->pt_ucntl = 0;

    /* Set ownership on slave device */
    pti->devs->si_uid = ap->a_cred->cr_uid;
    pti->devs->si_gid = ap->a_cred->cr_uid ? GID_TTY : 0;
    pti->devs->si_perms = 0600;

    pti->pt_flags |= PF_MOPEN;
    pti_done(pti);

    lwkt_reltoken(&tp->t_token);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (0);
}
```

### Reading from Master

`ptcread()` (`tty_pty.c:742`) retrieves slave output:

```c
static int
ptcread(struct dev_read_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp = dev->si_tty;
    struct pt_ioctl *pti = dev->si_drv1;
    char buf[BUFSIZ];
    int error = 0, cc;

    lwkt_gettoken(&pti->pt_tty.t_token);
    lwkt_gettoken(&tp->t_token);

    for (;;) {
        if (tp->t_state & TS_ISOPEN) {
            /* Handle packet mode events */
            if ((pti->pt_flags & PF_PKT) && pti->pt_send) {
                error = ureadc((int)pti->pt_send, ap->a_uio);
                if (error)
                    goto out;
                    
                /* Include termios on TIOCPKT_IOCTL */
                if (pti->pt_send & TIOCPKT_IOCTL) {
                    cc = szmin(ap->a_uio->uio_resid,
                               sizeof(tp->t_termios));
                    uiomove((caddr_t)&tp->t_termios, cc, ap->a_uio);
                }
                pti->pt_send = 0;
                goto out;
            }
            
            /* Handle user control mode */
            if ((pti->pt_flags & PF_UCNTL) && pti->pt_ucntl) {
                error = ureadc((int)pti->pt_ucntl, ap->a_uio);
                pti->pt_ucntl = 0;
                goto out;
            }
            
            /* Check for data in output queue */
            if (tp->t_outq.c_cc && (tp->t_state & TS_TTSTOP) == 0)
                break;
        }
        
        /* Check for disconnect */
        if ((tp->t_state & TS_CONNECTED) == 0) {
            error = 0;              /* EOF */
            goto out;
        }
        
        /* Non-blocking check */
        if (ap->a_ioflag & IO_NDELAY) {
            error = EWOULDBLOCK;
            goto out;
        }
        
        /* Sleep waiting for data */
        error = tsleep(TSA_PTC_READ(tp), PCATCH, "ptcin", 0);
        if (error)
            goto out;
    }

    /* Prepend status byte in packet/ucntl mode */
    if (pti->pt_flags & (PF_PKT|PF_UCNTL))
        error = ureadc(0, ap->a_uio);

    /* Copy data from output queue */
    while (ap->a_uio->uio_resid > 0 && error == 0) {
        cc = clist_qtob(&tp->t_outq, buf,
                        szmin(ap->a_uio->uio_resid, BUFSIZ));
        if (cc <= 0)
            break;
        error = uiomove(buf, cc, ap->a_uio);
    }
    
    /* Wake writers waiting for queue space */
    ttwwakeup(tp);

out:
    lwkt_reltoken(&tp->t_token);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (error);
}
```

### Writing to Master

`ptcwrite()` (`tty_pty.c:996`) sends input to the slave:

```c
static int
ptcwrite(struct dev_write_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp = dev->si_tty;
    u_char *cp = NULL;
    int cc = 0;
    u_char locbuf[BUFSIZ];
    int cnt = 0;
    struct pt_ioctl *pti = dev->si_drv1;
    int error = 0;

    lwkt_gettoken(&pti->pt_tty.t_token);
    lwkt_gettoken(&tp->t_token);
    
again:
    if ((tp->t_state & TS_ISOPEN) == 0)
        goto block;
        
    /* Remote mode: write directly to canonical queue */
    if (pti->pt_flags & PF_REMOTE) {
        if (tp->t_canq.c_cc)
            goto block;             /* Wait for queue to empty */
            
        while ((ap->a_uio->uio_resid > 0 || cc > 0) &&
               tp->t_canq.c_cc < TTYHOG - 1) {
            if (cc == 0) {
                cc = szmin(ap->a_uio->uio_resid, BUFSIZ);
                cc = imin(cc, TTYHOG - 1 - tp->t_canq.c_cc);
                cp = locbuf;
                error = uiomove(cp, cc, ap->a_uio);
                if (error)
                    goto out;
            }
            if (cc > 0) {
                cc = clist_btoq((char *)cp, cc, &tp->t_canq);
                if (cc > 0)
                    break;
            }
        }
        /* Adjust for unwritten data */
        ap->a_uio->uio_resid += cc;
        clist_putc(0, &tp->t_canq); /* Null terminator */
        ttwakeup(tp);
        wakeup(TSA_PTS_READ(tp));
        goto out;
    }
    
    /* Normal mode: feed through line discipline */
    while (ap->a_uio->uio_resid > 0 || cc > 0) {
        if (cc == 0) {
            cc = szmin(ap->a_uio->uio_resid, BUFSIZ);
            cp = locbuf;
            error = uiomove(cp, cc, ap->a_uio);
            if (error)
                goto out;
        }
        
        while (cc > 0) {
            /* Check for input queue overflow */
            if ((tp->t_rawq.c_cc + tp->t_canq.c_cc) >= TTYHOG - 2 &&
               (tp->t_canq.c_cc > 0 || !(tp->t_lflag & ICANON))) {
                wakeup(TSA_HUP_OR_INPUT(tp));
                goto block;
            }
            /* Process character through line discipline */
            (*linesw[tp->t_line].l_rint)(*cp++, tp);
            cnt++;
            cc--;
        }
        cc = 0;
    }
    goto out;

block:
    /* Wait for slave to open or queue space */
    if ((tp->t_state & TS_CONNECTED) == 0) {
        ap->a_uio->uio_resid += cc;
        error = EIO;
        goto out;
    }
    if (ap->a_ioflag & IO_NDELAY) {
        ap->a_uio->uio_resid += cc;
        error = (cnt == 0) ? EWOULDBLOCK : 0;
        goto out;
    }
    error = tsleep(TSA_PTC_WRITE(tp), PCATCH, "ptcout", 0);
    if (error) {
        ap->a_uio->uio_resid += cc;
        goto out;
    }
    goto again;

out:
    lwkt_reltoken(&tp->t_token);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (error);
}
```

### Closing the Master

`ptcclose()` (`tty_pty.c:687`) tears down the connection:

```c
static int
ptcclose(struct dev_close_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp;
    struct pt_ioctl *pti = dev->si_drv1;

    lwkt_gettoken(&pti->pt_tty.t_token);
    if (pti_hold(pti))
        panic("ptcclose on terminated pti");
        
    tp = dev->si_tty;
    lwkt_gettoken(&tp->t_token);

    /* Signal carrier loss to slave */
    (void)(*linesw[tp->t_line].l_modem)(tp, 0);

    /* Mark master closed, zombie if slave still open */
    pti->pt_flags &= ~PF_MOPEN;
    if (pti->pt_flags & PF_SOPEN)
        tp->t_state |= TS_ZOMBIE;

    /* Disconnect and flush */
    if (tp->t_state & TS_ISOPEN) {
        tp->t_state &= ~(TS_CARR_ON | TS_CONNECTED);
        ttyflush(tp, FREAD | FWRITE);
    }
    tp->t_oproc = NULL;             /* Mark as closed */

    /* Reset ownership */
    pti->pt_prison = NULL;
    pti->devs->si_uid = 0;
    pti->devs->si_gid = 0;
    pti->devs->si_perms = 0666;

    pti_done(pti);
    lwkt_reltoken(&tp->t_token);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (0);
}
```

## Slave Side Operations

### Opening the Slave

`ptsopen()` (`tty_pty.c:351`) connects to an existing master:

```c
static int
ptsopen(struct dev_open_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp;
    int error;
    struct pt_ioctl *pti;

    if (dev->si_drv1 == NULL)
        return(ENXIO);
    pti = dev->si_drv1;

    lwkt_gettoken(&pti->pt_tty.t_token);
    if (pti_hold(pti)) {
        lwkt_reltoken(&pti->pt_tty.t_token);
        return(ENXIO);
    }

    tp = dev->si_tty;

    /* Initialize tty on first open */
    if ((tp->t_state & TS_ISOPEN) == 0) {
        ttychars(tp);               /* Set default characters */
        tp->t_iflag = TTYDEF_IFLAG;
        tp->t_oflag = TTYDEF_OFLAG;
        tp->t_lflag = TTYDEF_LFLAG;
        tp->t_cflag = TTYDEF_CFLAG;
        tp->t_ispeed = tp->t_ospeed = TTYDEF_SPEED;
    } else if ((tp->t_state & TS_XCLUDE) &&
               caps_priv_check(ap->a_cred, SYSCAP_RESTRICTEDROOT)) {
        pti_done(pti);
        lwkt_reltoken(&pti->pt_tty.t_token);
        return (EBUSY);             /* Exclusive access */
    } else if (pti->pt_prison != ap->a_cred->cr_prison) {
        pti_done(pti);
        lwkt_reltoken(&pti->pt_tty.t_token);
        return (EBUSY);             /* Wrong jail */
    }

    /* Connect if master present, else clear zombie */
    if (tp->t_oproc)
        (void)(*linesw[tp->t_line].l_modem)(tp, 1);
    else if ((pti->pt_flags & PF_SOPEN) == 0)
        tp->t_state &= ~TS_ZOMBIE;

    /* Wait for carrier (master) */
    while ((tp->t_state & TS_CARR_ON) == 0) {
        if (ap->a_oflags & FNONBLOCK)
            break;
        error = ttysleep(tp, TSA_CARR_ON(tp), PCATCH, "ptsopn", 0);
        if (error) {
            pti_done(pti);
            lwkt_reltoken(&pti->pt_tty.t_token);
            return (error);
        }
    }

    /* Complete open via line discipline */
    error = (*linesw[tp->t_line].l_open)(dev, tp);

    if (error == 0) {
        pti->pt_flags |= PF_SOPEN;
        pti->pt_flags &= ~PF_SCLOSED;
        ptcwakeup(tp, FREAD|FWRITE);
    }
    
    pti_done(pti);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (error);
}
```

### Reading from Slave

`ptsread()` (`tty_pty.c:479`) reads processed input:

```c
static int
ptsread(struct dev_read_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct proc *p = curproc;
    struct tty *tp = dev->si_tty;
    struct pt_ioctl *pti = dev->si_drv1;
    struct lwp *lp;
    int error = 0;

    lp = curthread->td_lwp;
    lwkt_gettoken(&pti->pt_tty.t_token);
    
again:
    /* Remote mode: read from canonical queue directly */
    if (pti->pt_flags & PF_REMOTE) {
        /* Check for background process */
        while (isbackground(p, tp)) {
            if (SIGISMEMBER(p->p_sigignore, SIGTTIN) ||
                SIGISMEMBER(lp->lwp_sigmask, SIGTTIN) ||
                p->p_pgrp->pg_jobc == 0 ||
                (p->p_flags & P_PPWAIT)) {
                lwkt_reltoken(&pti->pt_tty.t_token);
                return (EIO);
            }
            pgsignal(p->p_pgrp, SIGTTIN, 1);
            error = ttysleep(tp, &lbolt, PCATCH, "ptsbg", 0);
            if (error) {
                lwkt_reltoken(&pti->pt_tty.t_token);
                return (error);
            }
        }
        
        /* Wait for data */
        if (tp->t_canq.c_cc == 0) {
            if (ap->a_ioflag & IO_NDELAY) {
                lwkt_reltoken(&pti->pt_tty.t_token);
                return (EWOULDBLOCK);
            }
            error = ttysleep(tp, TSA_PTS_READ(tp), PCATCH, "ptsin", 0);
            if (error) {
                lwkt_reltoken(&pti->pt_tty.t_token);
                return (error);
            }
            goto again;
        }
        
        /* Read until null terminator */
        while (tp->t_canq.c_cc > 1 && ap->a_uio->uio_resid > 0)
            if (ureadc(clist_getc(&tp->t_canq), ap->a_uio) < 0) {
                error = EFAULT;
                break;
            }
        if (tp->t_canq.c_cc == 1)
            clist_getc(&tp->t_canq);     /* Remove null terminator */
    } else {
        /* Normal mode: use line discipline */
        if (tp->t_oproc)
            error = (*linesw[tp->t_line].l_read)(tp, ap->a_uio,
                                                  ap->a_ioflag);
    }
    
    ptcwakeup(tp, FWRITE);
    lwkt_reltoken(&pti->pt_tty.t_token);
    return (error);
}
```

### Writing from Slave

`ptswrite()` (`tty_pty.c:548`) outputs through line discipline:

```c
static int
ptswrite(struct dev_write_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct tty *tp;
    int ret;

    tp = dev->si_tty;
    lwkt_gettoken(&tp->t_token);
    
    if (tp->t_oproc == NULL) {
        lwkt_reltoken(&tp->t_token);
        return (EIO);               /* No master */
    }
    
    ret = (*linesw[tp->t_line].l_write)(tp, ap->a_uio, ap->a_ioflag);
    lwkt_reltoken(&tp->t_token);
    return ret;
}
```

## Packet Mode

Packet mode (`TIOCPKT`) allows the master to receive out-of-band notifications
about slave state changes. This is used by applications like `rlogin` to
handle window size changes and flow control.

### Packet Mode Events

```c
/* Event flags sent to master (first byte of read) */
#define TIOCPKT_DATA        0x00    /* Normal data follows */
#define TIOCPKT_FLUSHREAD   0x01    /* Flush read queue */
#define TIOCPKT_FLUSHWRITE  0x02    /* Flush write queue */
#define TIOCPKT_STOP        0x04    /* Output stopped (^S) */
#define TIOCPKT_START       0x08    /* Output started (^Q) */
#define TIOCPKT_NOSTOP      0x10    /* No more ^S/^Q needed */
#define TIOCPKT_DOSTOP      0x20    /* Resume ^S/^Q processing */
#define TIOCPKT_IOCTL       0x40    /* Termios changed (followed by termios) */
```

### Enabling Packet Mode

```c
int flag = 1;
ioctl(master_fd, TIOCPKT, &flag);
```

### Reading Packet Mode Data

```c
char buf[1024];
int n = read(master_fd, buf, sizeof(buf));
if (n > 0) {
    if (buf[0] == TIOCPKT_DATA) {
        /* Normal data in buf[1..n-1] */
    } else {
        /* Status event in buf[0] */
        if (buf[0] & TIOCPKT_STOP)
            printf("Output stopped\n");
        if (buf[0] & TIOCPKT_START)
            printf("Output started\n");
        if (buf[0] & TIOCPKT_IOCTL) {
            /* struct termios follows in buf[1..] */
        }
    }
}
```

## Remote Mode

Remote mode (`TIOCREMOTE`) puts the PTY into a special state where all flow
control is handled by the master application. The master writes directly to
the canonical queue with explicit record boundaries.

```c
int flag = 1;
ioctl(master_fd, TIOCREMOTE, &flag);
```

In remote mode:
- Input bypasses line discipline processing
- Each write is null-terminated in `t_canq`
- Slave reads complete records at a time
- No automatic echo or editing

## User Control Mode

User control mode (`TIOCUCNTL`) allows the master to receive single-byte
control messages from the slave via special ioctls (`UIOCCMD(n)`):

```c
/* Enable on master */
int flag = 1;
ioctl(master_fd, TIOCUCNTL, &flag);

/* Slave sends control byte */
ioctl(slave_fd, UIOCCMD(42), NULL);

/* Master receives as first byte of read */
char buf[1];
read(master_fd, buf, 1);  /* buf[0] == 42 */
```

## Extended Processing

External processing (`EXTPROC`) mode indicates that an external program
(typically on a remote system) is handling line discipline processing:

```c
int flag = 1;
ioctl(fd, TIOCEXT, &flag);  /* Enable EXTPROC */
```

When enabled, local line editing is disabled and the master receives
`TIOCPKT_IOCTL` notifications when termios settings change.

## PTY-Specific ioctls

### Master-Side ioctls

| ioctl | Description |
|-------|-------------|
| `TIOCPKT` | Enable/disable packet mode |
| `TIOCUCNTL` | Enable/disable user control mode |
| `TIOCREMOTE` | Enable/disable remote mode |
| `TIOCISPTMASTER` | Check if device is Unix98 master |
| `TIOCSIG` | Send signal to slave process group |

### Common ioctls

| ioctl | Description |
|-------|-------------|
| `TIOCEXT` | Enable/disable external processing |
| `TIOCGPGRP` | Get foreground process group |
| `TIOCSPGRP` | Set foreground process group |
| `TIOCGWINSZ` | Get window size |
| `TIOCSWINSZ` | Set window size |

## Reference Counting and Cleanup

### Reference Management

`pti_hold()` and `pti_done()` manage references to prevent premature
destruction (`tty_pty.c:281`):

```c
static int
pti_hold(struct pt_ioctl *pti)
{
    if (pti->pt_flags & PF_TERMINATED)
        return(ENXIO);
    ++pti->pt_refs;
    return(0);
}

static void
pti_done(struct pt_ioctl *pti)
{
    lwkt_gettoken(&pti->pt_tty.t_token);
    if (--pti->pt_refs == 0) {
        /* Check for cleanup conditions */
        if ((pti->pt_flags & PF_UNIX98) == 0) {
            lwkt_reltoken(&pti->pt_tty.t_token);
            return;                 /* BSD PTYs never freed */
        }

        if ((pti->pt_flags & (PF_SOPEN|PF_MOPEN)) == 0 &&
            pti->pt_tty.t_refs == 0) {
            /* Both sides closed, no session reference */
            pti->pt_flags |= PF_TERMINATED;
            
            /* Destroy devices */
            if (pti->devs) {
                destroy_dev(pti->devs);
                pti->devs = NULL;
            }
            if (pti->devc) {
                destroy_dev(pti->devc);
                pti->devc = NULL;
            }
            
            ttyunregister(&pti->pt_tty);
            pti->pt_tty.t_dev = NULL;
            
            /* Release bitmap slot */
            devfs_clone_bitmap_put(&DEVFS_CLONE_BITMAP(pty),
                                   pti->pt_uminor);
            /* Note: pti structure remains allocated */
        }
    }
    lwkt_reltoken(&pti->pt_tty.t_token);
}
```

### Session Unhold Callback

The `ptsunhold()` callback handles the case where a session holds a reference
to the TTY after file descriptors are closed (`tty_pty.c:864`):

```c
static void
ptsunhold(struct tty *tp)
{
    struct pt_ioctl *pti = tp->t_dev->si_drv1;

    lwkt_gettoken(&pti->pt_tty.t_token);
    lwkt_gettoken(&tp->t_token);
    pti_hold(pti);
    --tp->t_refs;
    pti_done(pti);                  /* May trigger cleanup */
    lwkt_reltoken(&tp->t_token);
    lwkt_reltoken(&pti->pt_tty.t_token);
}
```

## kqueue Support

The PTY master supports kqueue for event notification (`tty_pty.c:886`):

```c
static int
ptckqfilter(struct dev_kqfilter_args *ap)
{
    cdev_t dev = ap->a_head.a_dev;
    struct knote *kn = ap->a_kn;
    struct tty *tp = dev->si_tty;
    struct klist *klist;

    switch (kn->kn_filter) {
    case EVFILT_READ:
        klist = &tp->t_rkq.ki_note;
        kn->kn_fop = &ptcread_filtops;
        break;
    case EVFILT_WRITE:
        klist = &tp->t_wkq.ki_note;
        kn->kn_fop = &ptcwrite_filtops;
        break;
    default:
        ap->a_result = EOPNOTSUPP;
        return (0);
    }

    kn->kn_hook = (caddr_t)dev;
    knote_insert(klist, kn);
    return (0);
}
```

Read filter returns true when output queue has data or packet events pending.
Write filter returns true when input queues have space.

## Synchronization

The PTY subsystem uses multiple tokens for synchronization:

```c
/* Typical locking pattern */
lwkt_gettoken(&pti->pt_tty.t_token);  /* PTY-specific state */
lwkt_gettoken(&tp->t_token);          /* TTY state */

/* ... access protected state ... */

lwkt_reltoken(&tp->t_token);
lwkt_reltoken(&pti->pt_tty.t_token);
```

Global token for allocation:
```c
lwkt_gettoken(&tty_token);            /* PTY array access */
```

## Initialization

PTY subsystem initialization (`tty_pty.c:1334`):

```c
static void
ptc_drvinit(void *unused)
{
    int i;

    /* Create /dev/ptmx clone device for Unix98 */
    make_autoclone_dev(&ptc_ops, &DEVFS_CLONE_BITMAP(pty), ptyclone,
                       0, 0, 0666, "ptmx");
    
    /* Allocate pti pointer array */
    ptis = kmalloc(sizeof(struct pt_ioctl *) * MAXPTYS, M_PTY,
                   M_WAITOK | M_ZERO);

    /* Pre-create 256 BSD-style PTYs */
    for (i = 0; i < 256; i++) {
        ptyinit(i);
    }
}

SYSINIT(ptcdev, SI_SUB_DRIVERS, SI_ORDER_MIDDLE + CDEV_MAJOR_C,
        ptc_drvinit, NULL);
```

## Debugging

Debug level controllable via sysctl:

```c
static int pty_debug_level = 0;
SYSCTL_INT(_kern, OID_AUTO, pty_debug, CTLFLAG_RW, &pty_debug_level,
           0, "Change pty debug level");
```

## Usage Example

### Opening a PTY Pair (Unix98)

```c
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

int master_fd = open("/dev/ptmx", O_RDWR | O_NOCTTY);
if (master_fd < 0)
    err(1, "open ptmx");

/* Get slave device path */
char *slave_path = ptsname(master_fd);

/* Grant and unlock slave */
grantpt(master_fd);
unlockpt(master_fd);

/* Open slave in child process */
int slave_fd = open(slave_path, O_RDWR);
```

### Typical Terminal Emulator Pattern

```c
pid_t pid = fork();
if (pid == 0) {
    /* Child: become session leader, set controlling terminal */
    setsid();
    int slave_fd = open(slave_path, O_RDWR);
    ioctl(slave_fd, TIOCSCTTY, 0);
    
    /* Redirect stdio */
    dup2(slave_fd, STDIN_FILENO);
    dup2(slave_fd, STDOUT_FILENO);
    dup2(slave_fd, STDERR_FILENO);
    close(slave_fd);
    
    execl("/bin/sh", "sh", NULL);
} else {
    /* Parent: communicate via master_fd */
    close(slave_fd);
    /* read/write master_fd ... */
}
```

## See Also

- [TTY Subsystem](tty.md) - Core terminal infrastructure
- [Processes](processes.md) - Process model and sessions
- [Signals](signals.md) - Signal delivery to process groups
- pty(4) - Pseudo-terminal driver manual page
- posix_openpt(3) - POSIX pseudo-terminal interface
