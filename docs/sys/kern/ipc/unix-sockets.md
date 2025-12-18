# Unix Domain Sockets

Unix domain sockets provide local inter-process communication using the familiar socket API. DragonFly BSD implements Unix domain sockets with LWKT token-based synchronization and reference counting for safe concurrent access across multiple processors.

## Overview

Unix domain sockets (also called local sockets) enable efficient communication between processes on the same machine without network protocol overhead. Key features include:

- **Filesystem binding** - Sockets can be bound to pathnames in the filesystem
- **File descriptor passing** - Transfer open file descriptors between processes
- **Credential passing** - Automatic sender credential transmission
- **Three socket types** - SOCK_STREAM, SOCK_DGRAM, and SOCK_SEQPACKET
- **Direct mbuf transfer** - Zero-copy data delivery to peer's receive buffer
- **Garbage collection** - Automatic cleanup of in-flight file descriptors

## Source Files

| File | Description |
|------|-------------|
| `sys/kern/uipc_usrreq.c` | Unix domain socket protocol implementation |
| `sys/sys/unpcb.h` | Unix domain protocol control block definitions |
| `sys/sys/un.h` | Unix domain socket address structure |

## Data Structures

### struct unpcb

The Unix domain protocol control block (`sys/sys/unpcb.h:68`):

```c
struct unpcb {
    struct socket   *unp_socket;    /* pointer back to socket */
    struct unpcb    *unp_conn;      /* control block of connected socket */
    int             unp_flags;      /* flags */
    int             unp_refcnt;     /* reference count */
    struct unp_head unp_refs;       /* referencing socket linked list (DGRAM) */
    LIST_ENTRY(unpcb) unp_reflink;  /* link in unp_refs list */
    struct sockaddr_un *unp_addr;   /* bound address of socket */
    struct xucred   unp_peercred;   /* peer credentials, if applicable */
    int             unp_msgcount;   /* # of cmsgs this unp are in */
    int             unp_gcflags;    /* flags reserved for unp GC to use */
    struct file     *unp_fp;        /* corresponding fp if unp is in cmsg */
    long            unp_unused01;
    struct vnode    *unp_vnode;     /* if associated with file */
    struct vnode    *unp_rvnode;    /* root vp for creating process (jail) */
    TAILQ_ENTRY(unpcb) unp_link;    /* glue on list of all PCBs */
    unp_gen_t       unp_gencnt;     /* generation count of this instance */
};
```

### struct sockaddr_un

The Unix domain socket address (`sys/sys/un.h`):

```c
struct sockaddr_un {
    uint8_t  sun_len;           /* total sockaddr length */
    sa_family_t sun_family;     /* AF_LOCAL / AF_UNIX */
    char     sun_path[104];     /* path name (null-terminated) */
};
```

### Global Socket Lists

Unix domain sockets are organized by type (`sys/kern/uipc_usrreq.c:124`):

```c
struct unp_global_head {
    struct unpcb_qhead  list;   /* TAILQ of unpcbs */
    int                 count;  /* number in list */
};

static struct unp_global_head unp_stream_head;   /* SOCK_STREAM sockets */
static struct unp_global_head unp_dgram_head;    /* SOCK_DGRAM sockets */
static struct unp_global_head unp_seqpkt_head;   /* SOCK_SEQPACKET sockets */
```

### UNP Flags

Protocol control block flags (`sys/sys/unpcb.h:102`):

| Flag | Value | Description |
|------|-------|-------------|
| `UNP_HAVEPC` | 0x001 | `unp_peercred` contains connected peer credentials |
| `UNP_HAVEPCCACHED` | 0x002 | `unp_peercred` cached from listen() |
| `UNP_DETACHED` | 0x004 | Socket detached from global list |
| `UNP_CONNECTING` | 0x008 | Connection in progress |
| `UNP_DROPPED` | 0x010 | Socket has been dropped |
| `UNP_MARKER` | 0x020 | Marker for list traversal |

## Synchronization

### Token Hierarchy

Unix domain sockets use a multi-level token hierarchy (`sys/kern/uipc_usrreq.c:185`):

```mermaid
flowchart TD
    A["unp_token<br/>(global)"]
    B["Per-unpcb pool token<br/>(lwkt_token_pool_lookup(unp))"]
    C["unp_rights_token<br/>(for file descriptor passing)"]
    
    A --> B --> C
```

**Rules:**

1. Any change to `unp_conn` requires **both** `unp_token` and the per-unpcb pool token
2. Access to `so_pcb` to obtain unp requires the pool token
3. File descriptor tracking (`unp_rights`) requires `unp_rights_token`

### Reference Counting

```c
static __inline void
unp_reference(struct unpcb *unp)
{
    KKASSERT(unp->unp_refcnt > 0);
    atomic_add_int(&unp->unp_refcnt, 1);
}

static __inline void
unp_free(struct unpcb *unp)
{
    KKASSERT(unp->unp_refcnt > 0);
    if (atomic_fetchadd_int(&unp->unp_refcnt, -1) == 1)
        unp_detach(unp);
}
```

### Socket Token Acquisition

`unp_getsocktoken()` safely acquires the pool token (`sys/kern/uipc_usrreq.c:215`):

```c
static __inline struct unpcb *
unp_getsocktoken(struct socket *so)
{
    struct unpcb *unp;

    /* The unp pointer is invalid until verified by re-checking
     * so_pcb AFTER obtaining the token. */
    while ((unp = so->so_pcb) != NULL) {
        lwkt_getpooltoken(unp);
        if (unp == so->so_pcb)
            break;
        lwkt_relpooltoken(unp);
    }
    return unp;
}
```

## Protocol Operations

### uipc_usrreqs

The protocol switch operations (`sys/kern/uipc_usrreq.c:905`):

```c
struct pr_usrreqs uipc_usrreqs = {
    .pru_abort = uipc_abort,
    .pru_accept = uipc_accept,
    .pru_attach = uipc_attach,
    .pru_bind = uipc_bind,
    .pru_connect = uipc_connect,
    .pru_connect2 = uipc_connect2,
    .pru_control = pr_generic_notsupp,
    .pru_detach = uipc_detach,
    .pru_disconnect = uipc_disconnect,
    .pru_listen = uipc_listen,
    .pru_peeraddr = uipc_peeraddr,
    .pru_rcvd = uipc_rcvd,
    .pru_rcvoob = pr_generic_notsupp,
    .pru_send = uipc_send,
    .pru_sense = uipc_sense,
    .pru_shutdown = uipc_shutdown,
    .pru_sockaddr = uipc_sockaddr,
    .pru_sosend = sosend,
    .pru_soreceive = soreceive
};
```

## Socket Lifecycle

### Attach

`unp_attach()` creates the protocol control block (`sys/kern/uipc_usrreq.c:1025`):

```mermaid
flowchart TD
    A["unp_attach(so, ai)"] --> B["Reserve buffer space based on socket type"]
    B --> B1["SOCK_STREAM: unpst_sendspace/recvspace (65536/65536)"]
    B --> B2["SOCK_DGRAM: unpdg_sendspace/recvspace (65536/65536)"]
    B --> B3["SOCK_SEQPACKET: unpsp_sendspace/recvspace (65536/65536)"]
    
    B1 --> C["For SOCK_STREAM: Set SSB_STOPSUPP on both buffers"]
    B2 --> C
    B3 --> C
    
    C --> D["Allocate unpcb (kmalloc M_UNPCB)"]
    
    D --> E["Initialize"]
    E --> E1["unp_refcnt = 1"]
    E --> E2["unp_gencnt = ++unp_gencnt"]
    E --> E3["LIST_INIT(&unp->unp_refs)"]
    E --> E4["unp_socket = so"]
    E --> E5["unp_rvnode = ai->fd_rdir (jail root)"]
    E --> E6["so->so_pcb = unp"]
    
    E1 --> F["Add to global type-specific list"]
    E2 --> F
    E3 --> F
    E4 --> F
    E5 --> F
    E6 --> F
```

### Bind

`unp_bind()` binds a socket to a filesystem path (`sys/kern/uipc_usrreq.c:1124`):

```mermaid
flowchart TD
    A["unp_bind(unp, nam, td)"] --> B["Check unp_vnode == NULL<br/>(not already bound)"]
    B --> C["Extract and null-terminate path from sockaddr_un"]
    C --> D["nlookup_init() with<br/>NLC_LOCKVP | NLC_CREATE | NLC_REFDVP"]
    D --> E["nlookup() → Find parent directory"]
    E --> F["Check path doesn't exist<br/>(EADDRINUSE)"]
    F --> G["VOP_NCREATE() → Create VSOCK vnode"]
    G --> G1["vattr.va_type = VSOCK"]
    G --> G2["vattr.va_mode = ACCESSPERMS & ~cmask"]
    G1 --> H["Link vnode to socket"]
    G2 --> H
    H --> H1["vp->v_socket = unp->unp_socket"]
    H --> H2["unp->unp_vnode = vp"]
    H --> H3["unp->unp_addr = dup_sockaddr(nam)"]
```

### Listen

`unp_listen()` prepares for incoming connections (`sys/kern/uipc_usrreq.c:2322`):

```c
static int
unp_listen(struct unpcb *unp, struct thread *td)
{
    struct proc *p = td->td_proc;

    KKASSERT(p);
    cru2x(p->p_ucred, &unp->unp_peercred);  /* Cache server credentials */
    unp_setflags(unp, UNP_HAVEPCCACHED);
    return (0);
}
```

The cached credentials are later copied to connecting clients.

### Connect

`unp_connect()` establishes a connection (`sys/kern/uipc_usrreq.c:1177`):

```mermaid
flowchart TD
    A["unp_connect(so, nam, td)"] --> B["Get socket token, check attached"]
    B --> C["Check not already connecting or connected"]
    C --> D["Set UNP_CONNECTING flag"]
    D --> E["unp_find_lockref() → Find and lock target unpcb"]
    E --> E1["nlookup() the path"]
    E --> E2["Check vnode type == VSOCK"]
    E --> E3["VOP_EACCESS() for VWRITE permission"]
    E --> E4["Lock and reference target unpcb"]
    
    E1 --> F{Socket Type?}
    E2 --> F
    E3 --> F
    E4 --> F
    
    F -->|STREAM/SEQPACKET| G["Connection-oriented"]
    F -->|DGRAM| H["Connectionless"]
    
    G --> G1["Check target has SO_ACCEPTCONN<br/>and UNP_HAVEPCCACHED"]
    G1 --> G2["sonewconn_faddr() →<br/>Create new socket for connection"]
    G2 --> G3["Copy server's bound address to new socket"]
    G3 --> G4["Exchange credentials"]
    G4 --> G4a["Client creds → new socket's unp_peercred"]
    G4 --> G4b["Server's cached creds → client's unp_peercred"]
    G4a --> G5["unp_connect_pair(unp, unp3)"]
    G4b --> G5
    
    H --> H1["unp_connect_pair(unp, unp2)"]
```

### Connect Pair

`unp_connect_pair()` links two sockets (`sys/kern/uipc_usrreq.c:2480`):

```c
static int
unp_connect_pair(struct unpcb *unp, struct unpcb *unp2)
{
    unp->unp_conn = unp2;

    switch (so->so_type) {
    case SOCK_DGRAM:
        /* DGRAM: one-way reference, unp2 keeps list of referrers */
        LIST_INSERT_HEAD(&unp2->unp_refs, unp, unp_reflink);
        soisconnected(so);
        break;

    case SOCK_STREAM:
    case SOCK_SEQPACKET:
        /* STREAM/SEQPACKET: bidirectional connection */
        unp2->unp_conn = unp;
        soisconnected(so);
        soisconnected(so2);
        break;
    }
    return 0;
}
```

## Data Transfer

### Send

`uipc_send()` transmits data (`sys/kern/uipc_usrreq.c:603`):

#### Datagram Send

```mermaid
flowchart TD
    A["uipc_send() [SOCK_DGRAM]"] --> B{"Address provided?"}
    B -->|Yes| C["Check not already connected"]
    C --> D["unp_find_lockref() → Find destination"]
    B -->|No| E["Use existing unp_conn"]
    D --> F{"SO_PASSCRED on receiver?"}
    E --> F
    F -->|Yes| G["Add SCM_CREDS control message"]
    F -->|No| H["Get receiver's ssb_token"]
    G --> H
    H --> I["ssb_appendaddr() → Append with source address"]
    I --> J["sorwakeup(so2)"]
```

#### Stream/Seqpacket Send

```mermaid
flowchart TD
    A["uipc_send() [SOCK_STREAM/SOCK_SEQPACKET]"] --> B["Connect if not connected and address provided"]
    B --> C["Check SS_CANTSENDMORE"]
    C --> D["Get peer's so_rcv.ssb_token"]
    D --> E["Transfer data directly to peer's receive buffer"]
    E --> E1["With control: ssb_appendcontrol()"]
    E --> E2["SEQPACKET: sbappendrecord()<br/>(preserve boundaries)"]
    E --> E3["STREAM: sbappend()<br/>(byte stream)"]
    E1 --> F{"Backpressure needed?"}
    E2 --> F
    E3 --> F
    F -->|"so2->so_rcv.ssb_cc >= so->so_snd.ssb_hiwat OR<br/>so2->so_rcv.ssb_mbcnt >= so->so_snd.ssb_mbmax"| G["atomic_set_int(&so->so_snd.ssb_flags, SSB_STOP)"]
    F -->|No| H["sorwakeup(so2)"]
    G --> H
```

### Receive Notification

`uipc_rcvd()` handles flow control after receive (`sys/kern/uipc_usrreq.c:539`):

```c
case SOCK_STREAM:
case SOCK_SEQPACKET:
    if (unp->unp_conn == NULL)
        break;
    unp2 = unp->unp_conn;
    so2 = unp2->unp_socket;

    unp_reference(unp2);
    lwkt_gettoken(&so2->so_rcv.ssb_token);

    /* Clear backpressure if buffer space available */
    if (so->so_rcv.ssb_cc < so2->so_snd.ssb_hiwat &&
        so->so_rcv.ssb_mbcnt < so2->so_snd.ssb_mbmax) {
        atomic_clear_int(&so2->so_snd.ssb_flags, SSB_STOP);
        sowwakeup(so2);  /* Wake sender */
    }

    lwkt_reltoken(&so2->so_rcv.ssb_token);
    unp_free(unp2);
    break;
```

## File Descriptor Passing

Unix domain sockets can transfer file descriptors between processes using ancillary data (SCM_RIGHTS).

### Internalize (Send Side)

`unp_internalize()` converts user FDs to kernel file pointers (`sys/kern/uipc_usrreq.c:1701`):

```mermaid
flowchart TD
    A["unp_internalize(control, td)"] --> B["Validate control message<br/>(SCM_RIGHTS or SCM_CREDS)"]
    B --> C{"Message type?"}
    C -->|SCM_CREDS| D["Fill in sender credentials and return"]
    C -->|SCM_RIGHTS| E["Calculate number of FDs:<br/>(cmsg_len - CMSG_LEN(0)) / sizeof(int)"]
    E --> F["Expand mbuf if needed for<br/>larger struct file pointers"]
    F --> G["Lock unp_rights_token and fd_spin"]
    G --> H["Validate all FDs"]
    H --> H1["Check fd < fd_nfiles"]
    H --> H2["Check fd_files[fd].fp != NULL"]
    H --> H3["Reject kqueues (EOPNOTSUPP)"]
    H1 --> I["Convert FDs to file pointers (reverse order)"]
    H2 --> I
    H3 --> I
    I --> I1["fp = fdescp->fd_files[fdp[i]].fp"]
    I --> I2["rp[i] = fp"]
    I --> I3["fhold(fp)"]
    I --> I4["unp_add_right(fp) - Track in-flight FDs"]
    I1 --> J["Update cmsg_len for pointer size"]
    I2 --> J
    I3 --> J
    I4 --> J
```

### Externalize (Receive Side)

`unp_externalize()` converts kernel file pointers to user FDs (`sys/kern/uipc_usrreq.c:1542`):

```mermaid
flowchart TD
    A["unp_externalize(rights, flags)"] --> B["Calculate number of file pointers"]
    B --> C["Check fdavail() for enough FD slots"]
    C --> D["Hold revoke_token (shared)<br/>to catch revoked files"]
    D --> E["For each file pointer"]
    E --> F["fdalloc() → Allocate new FD"]
    F --> G["unp_fp_externalize()"]
    G --> G1["Handle FREVOKED files specially"]
    G --> G2["Apply MSG_CMSG_CLOEXEC → UF_EXCLOSE"]
    G --> G3["Apply MSG_CMSG_CLOFORK → UF_FOCLOSE"]
    G --> G4["fsetfd() → Install in process FD table"]
    G --> G5["unp_del_right(fp) → Remove from in-flight count"]
    G --> G6["fdrop(fp)"]
    G1 --> H["Adjust cmsg_len for int size"]
    G2 --> H
    G3 --> H
    G4 --> H
    G5 --> H
    G6 --> H
```

### In-Flight Tracking

```c
static __inline void
unp_add_right(struct file *fp)
{
    struct unpcb *unp;

    ASSERT_LWKT_TOKEN_HELD(&unp_rights_token);

    unp = unp_fp2unpcb(fp);
    if (unp != NULL) {
        unp->unp_fp = fp;
        unp->unp_msgcount++;
    }
    fp->f_msgcount++;
    unp_rights++;  /* Global in-flight counter */
}

static __inline void
unp_del_right(struct file *fp)
{
    struct unpcb *unp;

    unp = unp_fp2unpcb(fp);
    if (unp != NULL) {
        unp->unp_msgcount--;
        if (unp->unp_msgcount == 0)
            unp->unp_fp = NULL;
    }
    fp->f_msgcount--;
    unp_rights--;
}
```

## Credential Passing

### SCM_CREDS

Sender credentials are passed via `unp_internalize()` when control message type is SCM_CREDS:

```c
if (cm->cmsg_type == SCM_CREDS) {
    cmcred = (struct cmsgcred *)CMSG_DATA(cm);
    cmcred->cmcred_pid = p->p_pid;
    cmcred->cmcred_uid = p->p_ucred->cr_ruid;
    cmcred->cmcred_gid = p->p_ucred->cr_rgid;
    cmcred->cmcred_euid = p->p_ucred->cr_uid;
    cmcred->cmcred_ngroups = MIN(p->p_ucred->cr_ngroups, CMGROUP_MAX);
    for (i = 0; i < cmcred->cmcred_ngroups; i++)
        cmcred->cmcred_groups[i] = p->p_ucred->cr_groups[i];
    return 0;
}
```

### SO_PASSCRED

When the receiving socket has `SO_PASSCRED` set, credentials are automatically included even if the sender didn't provide them:

```c
if (so2->so_options & SO_PASSCRED) {
    /* Check if SCM_CREDS already present */
    mp = &control;
    while ((ncon = *mp) != NULL) {
        cm = mtod(ncon, struct cmsghdr *);
        if (cm->cmsg_type == SCM_CREDS && cm->cmsg_level == SOL_SOCKET)
            break;
        mp = &ncon->m_next;
    }
    if (ncon == NULL) {
        /* Create and internalize credentials */
        ncon = sbcreatecontrol(&cred, sizeof(cred), SCM_CREDS, SOL_SOCKET);
        unp_internalize(ncon, msg->send.nm_td);
        *mp = ncon;
    }
}
```

### LOCAL_PEERCRED

Connected stream/seqpacket sockets can retrieve peer credentials:

```c
case LOCAL_PEERCRED:
    if (unp->unp_flags & UNP_HAVEPC)
        soopt_from_kbuf(sopt, &unp->unp_peercred, sizeof(unp->unp_peercred));
    else {
        if (so->so_type == SOCK_STREAM || so->so_type == SOCK_SEQPACKET)
            error = ENOTCONN;
        else
            error = EINVAL;
    }
    break;
```

## Garbage Collection

### Problem Statement

File descriptors passed over Unix domain sockets can form unreachable cycles:

1. Socket A holds a reference to socket B in its receive buffer
2. Socket B holds a reference to socket A in its receive buffer
3. Both sockets are closed by their owning processes
4. The file descriptors in flight keep each other alive indefinitely

### GC Algorithm

The garbage collector runs when `unp_rights > 0` and a socket is detached (`sys/kern/uipc_usrreq.c:2144`):

```mermaid
flowchart TD
    A["unp_gc()"] --> B["Clear all gcflags from previous runs"]
    B --> C["Mark phase (iterate until no new marks)"]
    C --> D["For each unpcb"]
    D --> E{"Already has UNPGC_REF?"}
    E -->|Yes| F["skip"]
    E -->|No| G{"Potentially in cycle?<br/>(all refs from messages)"}
    G -->|Yes| H["Mark UNPGC_DEAD,<br/>increment unp_unreachable"]
    G -->|No| I["Scan receive buffer"]
    I --> J["Mark referenced sockets with UNPGC_REF"]
    F --> K{"unp_marked == 0?"}
    H --> K
    J --> K
    K -->|No| D
    K -->|Yes| L["Sweep phase"]
    L --> M["Collect sockets marked UNPGC_DEAD"]
    M --> N["sorflush() each to release rights"]
    N --> O["fdrop() to release extra reference"]
```

### GC Flags

| Flag | Value | Description |
|------|-------|-------------|
| `UNPGC_REF` | 0x1 | Socket has external reference |
| `UNPGC_DEAD` | 0x2 | Socket might be in unreachable cycle |
| `UNPGC_SCANNED` | 0x4 | Socket's receive buffer has been scanned |

### Deferred Discard

To avoid deep recursion when discarding Unix domain sockets, disposal is deferred to a taskqueue:

```c
static void
unp_discard(struct file *fp, void *data __unused)
{
    unp_del_right(fp);
    if (unp_fp2unpcb(fp) != NULL) {
        /* This is a Unix socket - defer to avoid recursion */
        struct unp_defdiscard *d;

        d = kmalloc(sizeof(*d), M_UNPCB, M_WAITOK);
        d->fp = fp;

        spin_lock(&unp_defdiscard_spin);
        SLIST_INSERT_HEAD(&unp_defdiscard_head, d, next);
        spin_unlock(&unp_defdiscard_spin);

        taskqueue_enqueue(unp_taskqueue, &unp_defdiscard_task);
    } else {
        fdrop(fp);
    }
}
```

## Disconnect and Cleanup

### Disconnect

`unp_disconnect()` breaks a connection (`sys/kern/uipc_usrreq.c:1353`):

```c
static void
unp_disconnect(struct unpcb *unp, int error)
{
    struct socket *so = unp->unp_socket;
    struct unpcb *unp2;

    if (error)
        so->so_error = error;

    /* Get peer's token */
    while ((unp2 = unp->unp_conn) != NULL) {
        lwkt_getpooltoken(unp2);
        if (unp2 == unp->unp_conn)
            break;
        lwkt_relpooltoken(unp2);
    }
    if (unp2 == NULL)
        return;

    unp->unp_conn = NULL;

    switch (so->so_type) {
    case SOCK_DGRAM:
        LIST_REMOVE(unp, unp_reflink);
        soclrstate(so, SS_ISCONNECTED);
        break;

    case SOCK_STREAM:
    case SOCK_SEQPACKET:
        unp_reference(unp2);
        unp2->unp_conn = NULL;
        soisdisconnected(so);
        soisdisconnected(unp2->unp_socket);
        unp_free(unp2);
        break;
    }

    lwkt_relpooltoken(unp2);
}
```

### Drop

`unp_drop()` removes a socket from the system (`sys/kern/uipc_usrreq.c:2521`):

```mermaid
flowchart TD
    A["unp_drop(unp, error)"] --> B["Mark UNP_DETACHED"]
    B --> C["Remove from global list<br/>(stream/dgram/seqpkt)"]
    C --> D["unp_disconnect() → Break connection"]
    D --> E["For each socket referencing us (DGRAM)"]
    E --> F["unp_disconnect(unp2, ECONNRESET)"]
    F --> G["Mark UNP_DROPPED"]
    G --> H["unp_free() → Try to free"]
```

### Detach

`unp_detach()` performs final cleanup (`sys/kern/uipc_usrreq.c:1087`):

```c
static void
unp_detach(struct unpcb *unp)
{
    struct socket *so;

    lwkt_gettoken(&unp_token);
    lwkt_getpooltoken(unp);

    so = unp->unp_socket;

    unp->unp_gencnt = ++unp_gencnt;
    if (unp->unp_vnode) {
        unp->unp_vnode->v_socket = NULL;
        vrele(unp->unp_vnode);
        unp->unp_vnode = NULL;
    }
    soisdisconnected(so);
    so->so_pcb = NULL;
    unp->unp_socket = NULL;

    lwkt_relpooltoken(unp);
    lwkt_reltoken(&unp_token);

    sofree(so);

    if (unp->unp_addr)
        kfree(unp->unp_addr, M_SONAME);
    kfree(unp, M_UNPCB);

    /* Trigger GC if file descriptors still in flight */
    if (unp_rights)
        taskqueue_enqueue(unp_taskqueue, &unp_gc_task);
}
```

## Sysctl Parameters

Buffer size tunables (`sys/kern/uipc_usrreq.c:1005`):

| Sysctl | Default | Description |
|--------|---------|-------------|
| `net.local.stream.sendspace` | 65536 | Stream socket send buffer |
| `net.local.stream.recvspace` | 65536 | Stream socket receive buffer |
| `net.local.dgram.maxdgram` | 65536 | Maximum datagram size |
| `net.local.dgram.recvspace` | 65536 | Datagram socket receive buffer |
| `net.local.seqpacket.maxseqpacket` | 65536 | Maximum seqpacket size |
| `net.local.seqpacket.recvspace` | 65536 | Seqpacket receive buffer |
| `net.local.inflight` | (read-only) | File descriptors currently in flight |

PCB list access for netstat:

| Sysctl | Description |
|--------|-------------|
| `net.local.stream.pcblist` | List of active stream sockets |
| `net.local.dgram.pcblist` | List of active datagram sockets |
| `net.local.seqpacket.pcblist` | List of active seqpacket sockets |

## Jail Support

Unix domain sockets respect jail boundaries via `prison_unpcb()` (`sys/kern/uipc_usrreq.c:1416`):

```c
static int
prison_unpcb(struct thread *td, struct unpcb *unp)
{
    struct proc *p;

    if (td == NULL)
        return (0);
    if ((p = td->td_proc) == NULL)
        return (0);
    if (!p->p_ucred->cr_prison)
        return (0);
    /* Check if unp's root matches jail root */
    if (p->p_fd->fd_rdir == unp->unp_rvnode)
        return (0);
    return (1);  /* Reject - different jail */
}
```

The `unp_rvnode` field stores the root vnode of the process that created the socket, allowing cross-jail access to be filtered.

## Error Handling

Common error codes returned by Unix domain socket operations:

| Error | Condition |
|-------|-----------|
| `EINVAL` | Socket not attached, already bound, invalid address |
| `EADDRINUSE` | Bind path already exists |
| `ECONNREFUSED` | Target not listening, not attached, or connection rejected |
| `EPROTOTYPE` | Socket type mismatch |
| `EISCONN` | Already connected |
| `ENOTCONN` | Not connected (for connected operations) |
| `ENOTSOCK` | Path is not a socket |
| `ENOBUFS` | Buffer space exhausted |
| `EPIPE` | Cannot send (SS_CANTSENDMORE) |
| `EOPNOTSUPP` | Out-of-band data not supported |
| `EMSGSIZE` | Not enough FD slots for rights |
| `E2BIG` | Too many file descriptors in control message |
| `EBADF` | Invalid file descriptor in SCM_RIGHTS |

## See Also

- [Socket Layer](sockets.md) - Generic socket infrastructure
- [Mbufs](mbufs.md) - Memory buffer management
- [IPC Overview](../ipc.md) - Inter-process communication
- [Synchronization](../synchronization.md) - LWKT tokens and locking
