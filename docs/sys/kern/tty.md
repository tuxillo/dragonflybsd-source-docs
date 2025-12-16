# TTY Subsystem

The TTY (teletype) subsystem provides the kernel's terminal abstraction layer,
handling character I/O between user processes and terminal devices. This
subsystem implements line discipline processing, input/output queuing, job
control integration, and the classic UNIX terminal interface.

For historical context on terminal devices and their evolution from physical
teletypes to modern pseudo-terminals, see
[Wikipedia: Computer terminal](https://en.wikipedia.org/wiki/Computer_terminal).

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `sys/kern/tty.c` | 2,962 | Core TTY operations and processing |
| `sys/kern/tty_conf.c` | 185 | Line discipline configuration |
| `sys/kern/tty_subr.c` | 302 | Character list (clist) routines |
| `sys/kern/tty_cons.c` | 594 | Console device abstraction |
| `sys/kern/tty_tty.c` | 341 | Controlling terminal (`/dev/tty`) |
| `sys/sys/tty.h` | 293 | TTY structures and definitions |

## Architecture Overview

```
    User Process
         |
    read()/write()
         |
         v
  +-----------------+
  |   /dev/ttyXX    |  Device node (or /dev/tty, /dev/console)
  +-----------------+
         |
         v
  +-----------------+
  |  Line Discipline|  Input/output processing (canonical, raw, etc.)
  |    (linesw)     |
  +-----------------+
         |
         v
  +-----------------+
  |   struct tty    |  Per-terminal state and queues
  |   (t_rawq,      |
  |    t_canq,      |
  |    t_outq)      |
  +-----------------+
         |
    t_oproc()       Hardware-specific output
         |
         v
  +-----------------+
  |  Hardware/PTY   |  Physical device or pseudo-terminal
  +-----------------+
```

## Core Data Structures

### The TTY Structure

The `struct tty` (`sys/sys/tty.h:58`) is the central data structure representing
a terminal device:

```c
struct tty {
    struct lwkt_token t_token;      /* Per-tty token for MPSAFE */
    struct clist t_rawq;            /* Raw input queue (unprocessed) */
    struct clist t_canq;            /* Canonical input queue (line-edited) */
    struct clist t_outq;            /* Output queue */
    
    int     t_line;                 /* Line discipline index */
    int     t_state;                /* TS_* device and driver state */
    int     t_flags;                /* Pending state changes */
    
    struct pgrp *t_pgrp;            /* Foreground process group */
    struct session *t_session;      /* Enclosing session */
    
    struct termios t_termios;       /* Terminal attributes (POSIX) */
    struct winsize t_winsize;       /* Window size for TIOCGWINSZ */
    
    void    (*t_oproc)(struct tty *);   /* Start output routine */
    void    (*t_stop)(struct tty *, int); /* Stop output routine */
    int     (*t_param)(struct tty *, struct termios *); /* Set params */
    
    cdev_t  t_dev;                  /* Associated device */
    int     t_timeout;              /* Timeout for DCD check */
    int     t_gen;                  /* Generation count */
    
    /* Reference counting */
    struct ttyref *t_refs;          /* Reference list */
    int     t_refcnt;               /* Reference count */
};
```

### Terminal State Flags

The `t_state` field tracks the terminal's current state (`tty.h:145`):

```c
/* Device and driver state flags */
#define TS_SO_OLOWAT    0x00001   /* Wake when output drops below low water */
#define TS_ASYNC        0x00002   /* Asynchronous I/O mode (SIGIO) */
#define TS_BUSY         0x00004   /* Output in progress */
#define TS_CARR_ON      0x00008   /* Carrier is present (DCD) */
#define TS_FLUSH        0x00010   /* Flushing output */
#define TS_ISOPEN       0x00020   /* Device is open */
#define TS_TBLOCK       0x00040   /* Input blocked (tandem flow control) */
#define TS_TIMEOUT      0x00080   /* Wait for output drain timeout */
#define TS_TTSTOP       0x00100   /* Output stopped (^S or hardware) */
#define TS_ZOMBIE       0x00200   /* Connection lost */

/* State for input processing */
#define TS_ERASE        0x00400   /* Within multi-char erase sequence */
#define TS_LNCH         0x00800   /* Next char is literal (^V) */
#define TS_TYPEN        0x01000   /* Retyping suspended input */
#define TS_LOCAL        0x02000   /* Ignore carrier (CLOCAL) */
#define TS_CAN_BYPASS_L_RINT 0x10000  /* Can bypass l_rint for speed */

/* State for connection status */
#define TS_CONNECTED    0x20000   /* Connection open */
#define TS_REGISTERED   0x40000   /* TTY registered */
```

### The termios Structure

Terminal attributes are stored in POSIX `struct termios` (`sys/sys/_termios.h`):

```c
struct termios {
    tcflag_t c_iflag;       /* Input modes */
    tcflag_t c_oflag;       /* Output modes */
    tcflag_t c_cflag;       /* Control modes */
    tcflag_t c_lflag;       /* Local modes */
    cc_t     c_cc[NCCS];    /* Control characters */
    speed_t  c_ispeed;      /* Input baud rate */
    speed_t  c_ospeed;      /* Output baud rate */
};
```

Key flag groups:

| Field | Key Flags | Description |
|-------|-----------|-------------|
| `c_iflag` | `ICRNL`, `INLCR`, `IGNCR`, `IXON`, `IXOFF` | Input character mapping, flow control |
| `c_oflag` | `OPOST`, `ONLCR`, `OXTABS` | Output post-processing |
| `c_cflag` | `CLOCAL`, `CREAD`, `HUPCL`, `CSIZE`, `PARENB` | Hardware control, character size, parity |
| `c_lflag` | `ICANON`, `ECHO`, `ISIG`, `IEXTEN` | Canonical mode, echo, signals |
| `c_cc[]` | `VINTR`, `VQUIT`, `VERASE`, `VKILL`, `VEOF`, `VMIN`, `VTIME` | Special control characters |

## Line Disciplines

Line disciplines provide pluggable input/output processing. The default
terminal discipline handles canonical editing, while other disciplines
support protocols like SLIP and PPP.

### Line Discipline Interface

Each line discipline implements the `struct linesw` interface (`tty.h:213`):

```c
struct linesw {
    l_open_t    *l_open;    /* Open routine */
    l_close_t   *l_close;   /* Close routine */
    l_read_t    *l_read;    /* Read from input queue */
    l_write_t   *l_write;   /* Write to output queue */
    l_ioctl_t   *l_ioctl;   /* Discipline-specific ioctls */
    l_rint_t    *l_rint;    /* Receive input character */
    l_start_t   *l_start;   /* Start output */
    l_modem_t   *l_modem;   /* Modem status change */
};
```

### Available Disciplines

DragonFly supports several line disciplines (`tty_conf.c:63`):

| Index | Name | Description |
|-------|------|-------------|
| 0 | `TTYDISC` | Standard terminal discipline |
| 1 | `TABLDISC` | Tablet discipline (stub) |
| 2 | `SLIPDISC` | SLIP protocol (if compiled) |
| 3 | `PPPDISC` | PPP protocol (if compiled) |

### Registration API

Line disciplines register dynamically (`tty_conf.c:112`):

```c
int ldisc_register(int disc, struct linesw *lsw);
void ldisc_deregister(int disc);
```

The standard terminal discipline is implemented by:

```c
struct linesw termios_disc = {
    .l_open   = tty_open,      /* tty.c:389 */
    .l_close  = tty_close,     /* tty.c:435 */
    .l_read   = ttread,        /* tty.c:849 */
    .l_write  = ttwrite,       /* tty.c:1108 */
    .l_ioctl  = ttioctl,       /* tty.c:1377 */
    .l_rint   = ttyinput,      /* tty.c:504 */
    .l_start  = ttstart,       /* tty.c:2106 */
    .l_modem  = ttymodem       /* tty.c:2172 */
};
```

## Input Processing

Input processing transforms raw device input into processed data for
applications, handling special characters, line editing, and flow control.

### Input Character Flow

```
Hardware Interrupt
        |
        v
   ttyinput()              Receive single character
        |
   +----+----+
   |         |
   v         v
ICANON=0  ICANON=1
   |         |
   v         v
t_rawq    Line editing (erase, kill, etc.)
   |         |
   |         v
   |      t_canq (when line complete)
   |         |
   +----+----+
        |
        v
    ttread()              Process reads from queue
```

### The ttyinput() Function

`ttyinput()` (`tty.c:504`) processes each input character:

```c
int
ttyinput(int c, struct tty *tp)
{
    tcflag_t iflag = tp->t_iflag;
    tcflag_t lflag = tp->t_lflag;
    cc_t *cc = tp->t_cc;
    int i, err;

    /* Check for literal next (^V) */
    if (ISSET(tp->t_state, TS_LNCH)) {
        CLR(tp->t_state, TS_LNCH);
        /* Store character literally, even if special */
    }
    
    /* Input character mapping (ICRNL, INLCR, etc.) */
    if (c == '\r') {
        if (ISSET(iflag, IGNCR))
            return 0;               /* Ignore CR */
        else if (ISSET(iflag, ICRNL))
            c = '\n';               /* CR -> NL */
    } else if (c == '\n' && ISSET(iflag, INLCR))
        c = '\r';                   /* NL -> CR */
    
    /* Signal characters (ISIG mode) */
    if (ISSET(lflag, ISIG)) {
        if (CCEQ(cc[VINTR], c)) {
            pgsignal(tp->t_pgrp, SIGINT, 1);
            goto endcase;
        }
        if (CCEQ(cc[VQUIT], c)) {
            pgsignal(tp->t_pgrp, SIGQUIT, 1);
            goto endcase;
        }
        if (CCEQ(cc[VSUSP], c)) {
            pgsignal(tp->t_pgrp, SIGTSTP, 1);
            goto endcase;
        }
    }
    
    /* Flow control (IXON mode) */
    if (ISSET(iflag, IXON)) {
        if (CCEQ(cc[VSTOP], c)) {   /* ^S - stop output */
            if (!ISSET(tp->t_state, TS_TTSTOP)) {
                SET(tp->t_state, TS_TTSTOP);
                (*tp->t_stop)(tp, 0);
            }
            return 0;
        }
        if (CCEQ(cc[VSTART], c)) {  /* ^Q - start output */
            CLR(tp->t_state, TS_TTSTOP);
            goto restartoutput;
        }
    }
    
    /* Canonical mode editing */
    if (ISSET(lflag, ICANON)) {
        /* Handle ERASE (backspace), KILL (line delete), etc. */
        if (CCEQ(cc[VERASE], c)) {
            ttyrubo(tp, 1);         /* Rub out one character */
            return 0;
        }
        if (CCEQ(cc[VKILL], c)) {
            ttyflush(tp, FREAD);    /* Flush input */
            ttyecho(c, tp);
            return 0;
        }
    }
    
    /* Queue the character */
    if (ISSET(lflag, ICANON)) {
        if (CCEQ(cc[VEOF], c) || c == '\n') {
            /* Line complete - transfer to canonical queue */
            catq(&tp->t_rawq, &tp->t_canq);
            ttwakeup(tp);           /* Wake readers */
        } else {
            clist_putc(c, &tp->t_rawq);
        }
    } else {
        clist_putc(c, &tp->t_rawq);
        ttwakeup(tp);               /* Wake readers immediately */
    }
    
    /* Echo handling */
    if (ISSET(lflag, ECHO))
        ttyecho(c, tp);
    
    return 0;
}
```

### Canonical vs Raw Mode

**Canonical mode** (`ICANON` set):
- Input buffered until newline or EOF
- Line editing enabled (erase, kill, word-erase)
- Special characters processed (EOF, EOL)
- Data stored in `t_rawq`, transferred to `t_canq` on line completion

**Raw mode** (`ICANON` clear):
- Characters available immediately
- No line editing
- `VMIN`/`VTIME` control read behavior
- Data stored directly in `t_rawq`

### Input Tandem Flow Control

When input queues fill, tandem flow control prevents overflow (`tty.c:680`):

```c
/* If input high water mark reached, send STOP character */
if (tp->t_rawq.c_cc >= I_HIGH_WATER && ISSET(iflag, IXOFF)) {
    if (!ISSET(tp->t_state, TS_TBLOCK)) {
        SET(tp->t_state, TS_TBLOCK);
        ttstart(tp);    /* Send XOFF (^S) to remote */
    }
}
```

## Output Processing

Output processing transforms application data before transmission,
handling newline mapping, tab expansion, and flow control.

### The ttyoutput() Function

`ttyoutput()` (`tty.c:236`) processes a single output character:

```c
int
ttyoutput(int c, struct tty *tp)
{
    tcflag_t oflag = tp->t_oflag;
    int col;
    
    if (!ISSET(oflag, OPOST)) {
        /* Raw output - no processing */
        if (clist_putc(c, &tp->t_outq))
            return c;               /* Queue full */
        return -1;
    }
    
    /* ONLCR: Map NL to CR-NL */
    if (c == '\n' && ISSET(oflag, ONLCR)) {
        if (clist_putc('\r', &tp->t_outq))
            return c;
    }
    
    /* OXTABS: Expand tabs to spaces */
    if (c == '\t' && ISSET(oflag, OXTABS)) {
        col = 8 - (tp->t_column & 7);
        while (col-- > 0) {
            if (clist_putc(' ', &tp->t_outq))
                return c;
        }
        return -1;
    }
    
    /* Normal character */
    if (clist_putc(c, &tp->t_outq))
        return c;
    
    /* Update column tracking */
    switch (c) {
    case '\b':  if (tp->t_column > 0) tp->t_column--; break;
    case '\t':  tp->t_column = (tp->t_column + 8) & ~7; break;
    case '\n':  tp->t_column = 0; break;
    case '\r':  tp->t_column = 0; break;
    default:    if (c >= ' ') tp->t_column++; break;
    }
    
    return -1;
}
```

### Output Flow Control

Output stops when hardware or software flow control is active:

```c
/* Check if output should proceed */
void ttstart(struct tty *tp)
{
    if (!ISSET(tp->t_state, TS_TTSTOP | TS_TIMEOUT | TS_BUSY))
        (*tp->t_oproc)(tp);     /* Call hardware-specific output */
}
```

## Character Lists (Clist)

The clist subsystem provides efficient FIFO queues for terminal I/O,
implemented as circular buffers (`tty_subr.c`).

### Clist Structure

```c
struct clist {
    int     c_cc;       /* Character count */
    int     c_ccmax;    /* Maximum capacity */
    int     c_cchead;   /* Head index (read position) */
    short   *c_data;    /* Data buffer (with quote bits) */
};
```

The `short` data type stores both the character (low byte) and a quote bit
(high bit) that marks literal characters that should bypass special handling.

### Key Clist Operations

| Function | File:Line | Description |
|----------|-----------|-------------|
| `clist_alloc_cblocks()` | `tty_subr.c:68` | Allocate clist buffer |
| `clist_free_cblocks()` | `tty_subr.c:91` | Free clist buffer |
| `clist_getc()` | `tty_subr.c:107` | Get character from head |
| `clist_putc()` | `tty_subr.c:134` | Put character at tail |
| `b_to_q()` | `tty_subr.c:176` | Copy block to clist |
| `q_to_b()` | `tty_subr.c:212` | Copy clist to block |
| `unputc()` | `tty_subr.c:254` | Remove last character |
| `catq()` | `tty_subr.c:282` | Concatenate two clists |

### Clist Quoting

The quote bit marks characters as literal (`tty_subr.c:156`):

```c
int
clist_putc(int c, struct clist *cl)
{
    int i;
    
    if (cl->c_cc >= cl->c_ccmax)
        return -1;              /* Queue full */
    
    i = (cl->c_cchead + cl->c_cc) % cl->c_ccmax;
    cl->c_data[i] = (short)c;   /* Quote bit in high byte */
    cl->c_cc++;
    
    return 0;
}
```

## TTY Operations

### Opening a Terminal

`tty_open()` (`tty.c:389`) initializes a terminal for use:

```c
int
tty_open(cdev_t device, struct tty *tp)
{
    lwkt_gettoken(&tp->t_token);
    
    /* Initialize termios to sane defaults */
    if (!ISSET(tp->t_state, TS_ISOPEN)) {
        tp->t_termios = deftermios;     /* Default settings */
        SET(tp->t_state, TS_ISOPEN);
        bzero(&tp->t_winsize, sizeof(tp->t_winsize));
    }
    
    lwkt_reltoken(&tp->t_token);
    return 0;
}
```

### Reading from a Terminal

`ttread()` (`tty.c:849`) handles read operations:

```c
int
ttread(struct tty *tp, struct uio *uio, int flag)
{
    struct clist *qp;
    int c, first, error = 0;
    tcflag_t lflag;
    cc_t *cc = tp->t_cc;
    
    lwkt_gettoken(&tp->t_token);
    
loop:
    lflag = tp->t_lflag;
    
    /* Select appropriate queue */
    qp = ISSET(lflag, ICANON) ? &tp->t_canq : &tp->t_rawq;
    
    /* Check for carrier loss */
    if (!ISSET(tp->t_state, TS_CONNECTED)) {
        if (!ISSET(tp->t_state, TS_ZOMBIE)) {
            /* First detect - become zombie */
            SET(tp->t_state, TS_ZOMBIE);
        }
        lwkt_reltoken(&tp->t_token);
        return 0;                   /* EOF on carrier loss */
    }
    
    /* Wait for data if queue empty */
    if (qp->c_cc <= 0) {
        if (flag & IO_NDELAY) {
            lwkt_reltoken(&tp->t_token);
            return EWOULDBLOCK;
        }
        error = ttysleep(tp, TSA_HUP_OR_INPUT(tp),
                        PCATCH, "ttyin", 0);
        if (error)
            goto out;
        goto loop;
    }
    
    /* Read characters from queue */
    first = 1;
    while (uio->uio_resid > 0) {
        c = clist_getc(qp);
        if (c < 0)
            break;
        
        /* Check for EOF in canonical mode */
        if (ISSET(lflag, ICANON) && CCEQ(cc[VEOF], c))
            break;
        
        error = ureadc(c, uio);
        if (error)
            break;
        
        /* Line-delimited in canonical mode */
        if (ISSET(lflag, ICANON) && (c == '\n' || CCEQ(cc[VEOL], c)))
            break;
            
        first = 0;
    }
    
out:
    lwkt_reltoken(&tp->t_token);
    return error;
}
```

### Writing to a Terminal

`ttwrite()` (`tty.c:1108`) handles write operations:

```c
int
ttwrite(struct tty *tp, struct uio *uio, int flag)
{
    cc_t *cp;
    int cc, ce, c;
    int i, hiwat, cnt, error;
    char obuf[OBUFSIZ];
    
    lwkt_gettoken(&tp->t_token);
    
    hiwat = tp->t_ohiwat;
    cnt = uio->uio_resid;
    
loop:
    /* Wait if output queue full */
    while (tp->t_outq.c_cc > hiwat) {
        if (flag & IO_NDELAY) {
            if (cnt == uio->uio_resid) {
                lwkt_reltoken(&tp->t_token);
                return EWOULDBLOCK;
            }
            goto out;
        }
        
        SET(tp->t_state, TS_SO_OLOWAT);
        error = ttysleep(tp, TSA_OLOWAT(tp), PCATCH, "ttyout", hz);
        if (error)
            goto out;
    }
    
    /* Copy user data and process output */
    while (uio->uio_resid > 0) {
        cc = min(uio->uio_resid, OBUFSIZ);
        error = uiomove(obuf, cc, uio);
        if (error)
            break;
        
        /* Process each character through ttyoutput() */
        for (cp = obuf, ce = cc; ce > 0; cp++, ce--) {
            c = *cp;
            if (ttyoutput(c, tp) >= 0) {
                /* Queue full - wait for drain */
                ttstart(tp);
                goto loop;
            }
        }
    }
    
out:
    /* Start output */
    ttstart(tp);
    lwkt_reltoken(&tp->t_token);
    return error;
}
```

### Terminal ioctl Handling

`ttioctl()` (`tty.c:1377`) processes terminal control requests:

```c
int
ttioctl(struct tty *tp, u_long cmd, caddr_t data, int flag)
{
    struct proc *p = curproc;
    int error;
    
    lwkt_gettoken(&tp->t_token);
    
    switch (cmd) {
    /* Get terminal attributes */
    case TIOCGETA:
        bcopy(&tp->t_termios, data, sizeof(struct termios));
        break;
        
    /* Set terminal attributes */
    case TIOCSETA:
    case TIOCSETAW:     /* Wait for output drain first */
    case TIOCSETAF:     /* Flush input first */
        if (cmd == TIOCSETAW || cmd == TIOCSETAF) {
            error = ttywait(tp);
            if (error)
                goto out;
            if (cmd == TIOCSETAF)
                ttyflush(tp, FREAD);
        }
        bcopy(data, &tp->t_termios, sizeof(struct termios));
        /* Notify driver of parameter change */
        if (tp->t_param)
            (*tp->t_param)(tp, &tp->t_termios);
        break;
        
    /* Get/set window size */
    case TIOCGWINSZ:
        bcopy(&tp->t_winsize, data, sizeof(struct winsize));
        break;
    case TIOCSWINSZ:
        if (bcmp(&tp->t_winsize, data, sizeof(struct winsize))) {
            bcopy(data, &tp->t_winsize, sizeof(struct winsize));
            pgsignal(tp->t_pgrp, SIGWINCH, 1);
        }
        break;
        
    /* Get/set foreground process group */
    case TIOCGPGRP:
        *(int *)data = tp->t_pgrp ? tp->t_pgrp->pg_id : NO_PID;
        break;
    case TIOCSPGRP:
        error = tty_set_pgrp(tp, *(int *)data);
        break;
        
    /* Set controlling terminal */
    case TIOCSCTTY:
        error = tty_set_ctty(tp, p);
        break;
        
    /* Flush queues */
    case TIOCFLUSH:
        ttyflush(tp, *(int *)data);
        break;
        
    /* Send break */
    case TIOCSBRK:
    case TIOCCBRK:
        /* Passed to hardware driver */
        break;
    }
    
out:
    lwkt_reltoken(&tp->t_token);
    return error;
}
```

### Key ioctl Commands

| Command | Description |
|---------|-------------|
| `TIOCGETA` | Get terminal attributes (termios) |
| `TIOCSETA` | Set terminal attributes immediately |
| `TIOCSETAW` | Set attributes after output drains |
| `TIOCSETAF` | Set attributes after flush |
| `TIOCGWINSZ` | Get window size |
| `TIOCSWINSZ` | Set window size (sends SIGWINCH) |
| `TIOCGPGRP` | Get foreground process group |
| `TIOCSPGRP` | Set foreground process group |
| `TIOCSCTTY` | Set controlling terminal |
| `TIOCNOTTY` | Give up controlling terminal |
| `TIOCFLUSH` | Flush input/output queues |
| `TIOCCONS` | Redirect console output |
| `TIOCDRAIN` | Wait for output to drain |

## Console Subsystem

The console subsystem (`tty_cons.c`) provides a unified interface to the
system console, abstracting the underlying hardware (VGA, serial, etc.).

### Console Architecture

```
  kprintf() / printf()
         |
         v
    +---------+
    | cnputc()|     Kernel console output
    +---------+
         |
         v
    +---------+
    | cn_tab  |     Active console driver
    +---------+
         |
    cn_putc()       Hardware-specific output
         |
         v
    +---------+
    |  VGA /  |
    | Serial  |
    +---------+
```

### Console Device Structure

```c
struct consdev {
    cn_probe_t  *cn_probe;      /* Probe for hardware */
    cn_init_t   *cn_init;       /* Initialize hardware */
    cn_init_t   *cn_init_fini;  /* Finalize initialization */
    cn_term_t   *cn_term;       /* Terminate console */
    cn_getc_t   *cn_getc;       /* Get character (polled) */
    cn_checkc_t *cn_checkc;     /* Check for character */
    cn_putc_t   *cn_putc;       /* Output character (polled) */
    cn_poll_t   *cn_poll;       /* Poll mode control */
    cn_dbctl_t  *cn_dbctl;      /* Debugger control */
    
    short       cn_pri;         /* Priority (CN_DEAD to CN_REMOTE) */
    short       cn_probegood;   /* Probe succeeded */
    void        *cn_private;    /* Driver-private data */
    cdev_t      cn_dev;         /* Associated device */
};
```

### Console Priority Levels

```c
#define CN_DEAD     0   /* Device doesn't exist */
#define CN_NORMAL   1   /* Normal priority (VGA) */
#define CN_INTERNAL 2   /* Fallback internal device */
#define CN_REMOTE   3   /* High priority (serial console) */
```

### Console Initialization

`cninit()` (`tty_cons.c:140`) probes and initializes the console:

```c
void cninit(void)
{
    struct consdev *best_cp, *cp, **list;
    
    /* Find console with highest priority */
    best_cp = NULL;
    SET_FOREACH(list, cons_set) {
        cp = *list;
        if (cp->cn_probe == NULL)
            continue;
        (*cp->cn_probe)(cp);
        if (cp->cn_pri > CN_DEAD && cp->cn_probegood &&
            (best_cp == NULL || cp->cn_pri > best_cp->cn_pri))
            best_cp = cp;
    }
    
    /* Initialize selected console */
    if (best_cp != NULL) {
        (*best_cp->cn_init)(best_cp);
        if (cn_tab != NULL && cn_tab != best_cp)
            if (cn_tab->cn_term != NULL)
                (*cn_tab->cn_term)(cn_tab);
    }
    cn_tab = best_cp;
}
```

### Console I/O Functions

| Function | Description |
|----------|-------------|
| `cnputc()` | Output character to console |
| `cngetc()` | Get character from console (blocking) |
| `cncheckc()` | Check for pending character (non-blocking) |
| `cnpoll()` | Enable/disable polled mode |

### Console Muting

The console can be muted for security (`tty_cons.c:258`):

```c
/* Controlled via sysctl kern.consmute */
static int cn_mute;

SYSCTL_PROC(_kern, OID_AUTO, consmute, CTLTYPE_INT|CTLFLAG_RW,
    0, sizeof cn_mute, sysctl_kern_consmute, "I", "");
```

## Controlling Terminal (/dev/tty)

The `/dev/tty` device (`tty_tty.c`) provides each process access to its
controlling terminal, if any.

### The cttyvp() Macro

```c
#define cttyvp(p) (((p)->p_flags & P_CONTROLT) ? \
                    (p)->p_session->s_ttyvp : NULL)
```

A process has a controlling terminal when:
1. `P_CONTROLT` flag is set in `p_flags`
2. Session has a valid `s_ttyvp` (controlling terminal vnode)

### Device Operations

The ctty device redirects operations to the actual controlling terminal:

```c
static int cttyread(struct dev_read_args *ap)
{
    struct proc *p = curproc;
    struct vnode *ttyvp;
    int error;
    
    ttyvp = cttyvp(p);
    if (ttyvp == NULL)
        return (EIO);       /* No controlling terminal */
    
    error = vget(ttyvp, LK_EXCLUSIVE | LK_RETRY);
    if (error == 0) {
        error = VOP_READ(ttyvp, ap->a_uio, ap->a_ioflag, NOCRED);
        vput(ttyvp);
    }
    return (error);
}
```

### Controlling Terminal ioctls

Special handling for controlling terminal ioctls (`tty_tty.c:231`):

```c
static int cttyioctl(struct dev_ioctl_args *ap)
{
    struct vnode *ttyvp;
    struct proc *p = curproc;
    
    ttyvp = cttyvp(p);
    if (ttyvp == NULL)
        return (EIO);
    
    /* Prevent infinite recursion */
    if (ap->a_cmd == TIOCSCTTY)
        return EINVAL;
    
    /* Handle TIOCNOTTY for non-session-leaders */
    if (ap->a_cmd == TIOCNOTTY) {
        if (!SESS_LEADER(p)) {
            p->p_flags &= ~P_CONTROLT;
            return (0);
        }
        return (EINVAL);
    }
    
    return (VOP_IOCTL(ttyvp, ap->a_cmd, ap->a_data,
                      ap->a_fflag, ap->a_cred, ap->a_sysmsg));
}
```

## Job Control Integration

The TTY subsystem integrates tightly with job control, managing foreground
process groups and delivering signals.

### Session and Process Group Association

```c
/* Assign controlling terminal to session */
int tty_set_ctty(struct tty *tp, struct proc *p)
{
    struct session *sess = p->p_session;
    
    /* Must be session leader without existing ctty */
    if (!SESS_LEADER(p) || sess->s_ttyvp != NULL)
        return EPERM;
    
    sess->s_ttyp = tp;
    tp->t_session = sess;
    tp->t_pgrp = p->p_pgrp;
    p->p_flags |= P_CONTROLT;
    
    return 0;
}
```

### Signal Delivery

Input signals are sent to the foreground process group:

```c
/* Signal handling in ttyinput() */
if (CCEQ(cc[VINTR], c)) {
    pgsignal(tp->t_pgrp, SIGINT, 1);    /* ^C */
}
if (CCEQ(cc[VQUIT], c)) {
    pgsignal(tp->t_pgrp, SIGQUIT, 1);   /* ^\ */
}
if (CCEQ(cc[VSUSP], c)) {
    pgsignal(tp->t_pgrp, SIGTSTP, 1);   /* ^Z */
}
```

### Hangup Handling

`ttymodem()` (`tty.c:2172`) handles carrier detect changes:

```c
int ttymodem(struct tty *tp, int flag)
{
    if (flag) {
        /* Carrier detected */
        SET(tp->t_state, TS_CARR_ON | TS_CONNECTED);
        wakeup(TSA_CARR_ON(tp));
    } else {
        /* Carrier lost */
        if (!ISSET(tp->t_state, TS_ZOMBIE)) {
            SET(tp->t_state, TS_ZOMBIE);
            ttyflush(tp, FREAD | FWRITE);
            if (tp->t_session && tp->t_session->s_leader) {
                ksignal(tp->t_session->s_leader, SIGHUP);
            }
            pgsignal(tp->t_pgrp, SIGHUP, 1);
        }
    }
    return !ISSET(tp->t_state, TS_ZOMBIE);
}
```

## Synchronization

The TTY subsystem uses per-terminal tokens for MPSAFE operation.

### TTY Token

Each terminal has a dedicated token (`tty.h:58`):

```c
struct tty {
    struct lwkt_token t_token;  /* Per-tty token */
    ...
};
```

### Locking Pattern

```c
void some_tty_operation(struct tty *tp)
{
    lwkt_gettoken(&tp->t_token);
    
    /* Protected access to tty state */
    ...
    
    lwkt_reltoken(&tp->t_token);
}
```

### Global Tokens

Two global tokens protect console and VGA state (`tty_cons.c:152`):

```c
lwkt_gettoken(&tty_token);    /* General TTY operations */
lwkt_gettoken(&vga_token);    /* VGA console access */
```

## Sleeping and Wakeup

### Sleep Addresses

The TTY subsystem uses macros for typed sleep addresses:

```c
#define TSA_CARR_ON(tp)     ((void *)&(tp)->t_rawq)
#define TSA_HUP_OR_INPUT(tp) ((void *)&(tp)->t_rawq.c_cc)
#define TSA_OLOWAT(tp)      ((void *)&(tp)->t_outq)
#define TSA_OCOMPLETE(tp)   ((void *)&(tp)->t_outq.c_cc)
```

### ttysleep()

`ttysleep()` (`tty.c:2054`) wraps sleeping with generation count:

```c
int ttysleep(struct tty *tp, void *chan, int slpflags,
             char *wmesg, int timo)
{
    int gen = tp->t_gen;
    int error;
    
    error = tsleep(chan, slpflags, wmesg, timo);
    
    /* Check if tty was revoked while sleeping */
    if (error == 0 && gen != tp->t_gen)
        error = ERESTART;
    
    return error;
}
```

### Wakeup Functions

| Function | Description |
|----------|-------------|
| `ttwakeup()` | Wake readers waiting on input |
| `ttwwakeup()` | Wake writers waiting for output queue space |

## Debugging Interface

The console provides direct kernel access for debugging:

```c
/* Break to debugger configuration */
int break_to_debugger;      /* CTL-ALT-ESC on keyboard */
int alt_break_to_debugger;  /* CR ~ ^B on serial */

SYSCTL_INT(_kern, OID_AUTO, break_to_debugger, CTLFLAG_RW,
    &break_to_debugger, 0, "");
SYSCTL_INT(_kern, OID_AUTO, alt_break_to_debugger, CTLFLAG_RW,
    &alt_break_to_debugger, 0, "");
```

The `cndbctl()` function (`tty_cons.c:571`) enables/disables debugger mode.

## See Also

- [Pseudo-Terminals (PTY)](tty-pty.md) - Master/slave pseudo-terminal implementation
- [Processes](processes.md) - Process model and job control
- [Signals](signals.md) - Signal delivery mechanisms
- [Devices](devices.md) - Device driver framework
- [IPC](ipc.md) - Inter-process communication overview
- termios(4) - Terminal interface manual page
