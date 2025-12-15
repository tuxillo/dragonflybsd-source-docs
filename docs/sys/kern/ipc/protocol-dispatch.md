# Protocol Dispatch

The protocol dispatch layer provides the framework for routing socket operations to protocol-specific handlers in DragonFly BSD. It manages protocol registration, domain initialization, and message-based operation dispatch using the LWKT subsystem for multi-processor scalability.

## Overview

DragonFly's protocol dispatch architecture consists of three main components:

- **Domains** - Protocol families (e.g., AF_LOCAL, AF_INET) that group related protocols
- **Protocol Switch** - Tables mapping socket types to protocol handlers
- **Network Messages** - LWKT messages that dispatch operations to protocol threads

This design allows protocol operations to execute on dedicated threads, avoiding lock contention and enabling parallel processing across CPUs.

## Source Files

| File | Description |
|------|-------------|
| `sys/kern/uipc_domain.c` | Domain management and initialization |
| `sys/kern/uipc_proto.c` | Local domain protocol registration |
| `sys/kern/uipc_msg.c` | Network message dispatch wrappers |
| `sys/sys/domain.h` | Domain structure definition |
| `sys/sys/protosw.h` | Protocol switch structure and flags |
| `sys/net/netmsg.h` | Network message structures |

## Data Structures

### struct domain

The domain structure (`sys/sys/domain.h:44`) groups protocols by address family:

```c
struct domain {
    int     dom_family;             /* AF_xxx */
    char    *dom_name;              /* domain name (e.g., "local") */
    void    (*dom_init)(void);      /* initialization routine */
    int     (*dom_externalize)(struct mbuf *, int, struct thread *);
                                    /* externalize access rights */
    void    (*dom_dispose)(struct mbuf *);
                                    /* dispose of internalized rights */
    struct  protosw *dom_protosw;   /* protocol switch table start */
    struct  protosw *dom_protoswNPROTOSW;
                                    /* protocol switch table end */
    SLIST_ENTRY(domain) dom_next;   /* next domain in list */
    int     (*dom_rtattach)(void **, int);
                                    /* initialize routing table */
    int     dom_rtoffset;           /* arg to rtattach (sockaddr offset) */
    int     dom_maxrtkey;           /* for routing layer */
    void    *(*dom_ifattach)(struct ifnet *);
                                    /* per-interface attach */
    void    (*dom_ifdetach)(struct ifnet *, void *);
                                    /* per-interface detach */
};
```

Key fields:

- **`dom_family`** - Address family identifier (AF_LOCAL, AF_INET, AF_INET6, etc.)
- **`dom_externalize`** - Called to externalize access rights in control messages (used by Unix domain sockets for file descriptor passing)
- **`dom_dispose`** - Called to dispose of internalized access rights
- **`dom_protosw` / `dom_protoswNPROTOSW`** - Bounds of the protocol switch array for this domain

### struct protosw

The protocol switch structure (`sys/sys/protosw.h:86`) defines protocol behavior:

```c
struct protosw {
    short   pr_type;                /* socket type (SOCK_STREAM, etc.) */
    const struct domain *pr_domain; /* back pointer to domain */
    short   pr_protocol;            /* protocol number, if any */
    short   pr_flags;               /* protocol flags (PR_*) */

    /* Protocol-layer operations (rarely used directly) */
    void    (*pr_input)(struct mbuf *, ...);
                                    /* input from below */
    int     (*pr_output)(struct mbuf *, struct socket *, ...);
                                    /* output to network */
    void    (*pr_ctlinput)(int, struct sockaddr *, void *, void *);
                                    /* control input */
    int     (*pr_ctloutput)(struct socket *, struct sockopt *);
                                    /* control output */

    /* Initialization */
    void    (*pr_init)(void);       /* protocol init */

    /* Timer (deprecated) */
    void    (*pr_fasttimo)(void);   /* fast timeout */
    void    (*pr_slowtimo)(void);   /* slow timeout */

    /* Drain excess resources */
    void    (*pr_drain)(void);

    /* User-request operations */
    struct  pr_usrreqs *pr_usrreqs;
};
```

### Protocol Flags (PR_*)

Protocol flags control dispatch behavior (`sys/sys/protosw.h:129`):

| Flag | Value | Description |
|------|-------|-------------|
| `PR_ATOMIC` | 0x01 | Exchange atomic messages only |
| `PR_ADDR` | 0x02 | Addresses given with messages |
| `PR_CONNREQUIRED` | 0x04 | Connection required for data transfer |
| `PR_WANTRCVD` | 0x08 | Protocol wants `pru_rcvd` calls |
| `PR_RIGHTS` | 0x10 | Protocol supports access rights passing |
| `PR_SYNC_PORT` | 0x20 | Use synchronous port (netisr_sync_port) |
| `PR_ASYNC_SEND` | 0x40 | Allow asynchronous `pru_send` |
| `PR_ASYNC_RCVD` | 0x80 | Allow asynchronous `pru_rcvd` |
| `PR_MPSAFE` | 0x0100 | Protocol handler is MP-safe |

**Key flag semantics:**

- **`PR_ATOMIC`** - Each send/receive operates on complete messages (datagrams)
- **`PR_CONNREQUIRED`** - Stream protocols requiring connection before data transfer
- **`PR_SYNC_PORT`** - Forces all operations through a single serializing port
- **`PR_ASYNC_SEND` / `PR_ASYNC_RCVD`** - Enable fire-and-forget message dispatch for performance

### struct pr_usrreqs

User request handlers for socket operations (`sys/sys/protosw.h:158`):

```c
struct pr_usrreqs {
    void    (*pru_abort)(netmsg_t);         /* abort connection */
    void    (*pru_accept)(netmsg_t);        /* accept incoming conn */
    void    (*pru_attach)(netmsg_t);        /* attach protocol */
    void    (*pru_bind)(netmsg_t);          /* bind to address */
    void    (*pru_connect)(netmsg_t);       /* connect to peer */
    void    (*pru_connect2)(netmsg_t);      /* connect two sockets */
    void    (*pru_control)(netmsg_t);       /* ioctl operations */
    void    (*pru_detach)(netmsg_t);        /* detach protocol */
    void    (*pru_disconnect)(netmsg_t);    /* disconnect */
    void    (*pru_listen)(netmsg_t);        /* listen for connections */
    void    (*pru_peeraddr)(netmsg_t);      /* get peer address */
    void    (*pru_rcvd)(netmsg_t);          /* received data consumed */
    void    (*pru_rcvoob)(netmsg_t);        /* receive OOB data */
    void    (*pru_send)(netmsg_t);          /* send data */
    void    (*pru_sense)(netmsg_t);         /* stat-like operation */
    void    (*pru_shutdown)(netmsg_t);      /* shutdown connection */
    void    (*pru_sockaddr)(netmsg_t);      /* get local address */
    void    (*pru_sosend)(struct socket *, struct sockaddr *,
                          struct uio *, struct mbuf *,
                          struct mbuf *, int, struct thread *);
                                            /* optimized send path */
    void    (*pru_soreceive)(struct socket *, struct sockaddr **,
                             struct uio *, struct sockbuf *,
                             struct mbuf **, int *);
                                            /* optimized receive path */
    void    (*pru_savefaddr)(struct socket *, const struct sockaddr *);
                                            /* save foreign address */
};
```

All standard handlers take a `netmsg_t` parameter, which encapsulates the operation request and allows asynchronous execution.

### Network Message Structures

Network messages (`sys/net/netmsg.h`) carry operation requests between threads:

```c
struct netmsg_base {
    struct lwkt_msg     nm_lmsg;        /* LWKT message header */
    netisr_fn_t         nm_dispatch;    /* dispatch handler */
    struct socket       *nm_so;         /* associated socket */
};

typedef union netmsg *netmsg_t;
```

Operation-specific message types extend `netmsg_base`:

```c
struct netmsg_pru_attach {
    struct netmsg_base  base;
    int                 nm_proto;       /* protocol number */
    struct pru_attach_info *nm_ai;      /* attach info */
};

struct netmsg_pru_connect {
    struct netmsg_base  base;
    struct sockaddr     *nm_nam;        /* target address */
    struct thread       *nm_td;         /* calling thread */
    struct mbuf         *nm_m;          /* data mbuf (for sendto) */
    int                 nm_flags;       /* flags */
    int                 nm_reconnect;   /* reconnect indicator */
};

struct netmsg_pru_send {
    struct netmsg_base  base;
    int                 nm_flags;       /* MSG_* flags */
    int                 nm_priv;        /* privilege level */
    struct mbuf         *nm_m;          /* data mbuf chain */
    struct sockaddr     *nm_addr;       /* target address */
    struct mbuf         *nm_control;    /* control mbuf */
    struct thread       *nm_td;         /* calling thread */
};

struct netmsg_pru_rcvd {
    struct netmsg_base  base;
    int                 nm_flags;       /* MSG_* flags */
    int                 nm_pru_flags;   /* PRUR_* flags */
};
```

## Domain Registration

### DOMAIN_SET Macro

Domains register themselves using the `DOMAIN_SET()` macro (`sys/sys/domain.h:74`):

```c
#define DOMAIN_SET(name)                                        \
    SYSINIT(domain_add_ ## name, SI_SUB_PROTO_DOMAIN,           \
            SI_ORDER_FIRST, net_add_domain, &name ## domain)

/* Example from uipc_proto.c */
DOMAIN_SET(local);
```

This creates a SYSINIT entry that calls `net_add_domain()` during the `SI_SUB_PROTO_DOMAIN` initialization phase.

### Domain Registration Flow

```
boot
 │
 ├─► SI_SUB_PROTO_DOMAIN phase
 │       │
 │       ├─► net_add_domain(&localdomain)
 │       ├─► net_add_domain(&inetdomain)
 │       ├─► net_add_domain(&inet6domain)
 │       └─► ... (other domains)
 │
 └─► SI_SUB_PROTO_END phase
         │
         └─► net_init_domains()
                 │
                 └─► For each registered domain:
                         net_init_domain(dom)
```

### net_add_domain()

Adds a domain to the global list (`sys/kern/uipc_domain.c:99`):

```c
void net_add_domain(void *data)
{
    struct domain *dp = data;

    crit_enter();
    SLIST_INSERT_HEAD(&domains, dp, dom_next);
    crit_exit();
}
```

### net_init_domain()

Initializes a domain and its protocols (`sys/kern/uipc_domain.c:110`):

```c
static void net_init_domain(struct domain *dp)
{
    struct protosw *pr;
    u_char pr_flags[256];       /* Track protocol flags by protocol number */
    int warn_deprecation;

    /* Skip if no protocols */
    if (dp->dom_protosw == NULL)
        return;

    /* Check for deprecated timer callbacks */
    warn_deprecation = 0;

    /* Initialize each protocol in the domain */
    for (pr = dp->dom_protosw; pr < dp->dom_protoswNPROTOSW; pr++) {
        /* Fill in default user request handlers if not specified */
        pr_usrreqs_init(pr);

        /* Track and validate protocol flags */
        if (pr->pr_protocol && pr->pr_protocol < 256) {
            if (pr_flags[pr->pr_protocol])
                kprintf("domain %s: duplicate proto %d\n",
                        dp->dom_name, pr->pr_protocol);
            pr_flags[pr->pr_protocol] = pr->pr_flags;
        }

        /* Call protocol's init function */
        if (pr->pr_init)
            (*pr->pr_init)();

        /* Deprecated: timer callbacks */
        if (pr->pr_fasttimo || pr->pr_slowtimo)
            warn_deprecation = 1;
    }

    /* Call domain's init function */
    if (dp->dom_init)
        (*dp->dom_init)();

    if (warn_deprecation)
        kprintf("domain %s: pr_fasttimo or pr_slowtimo "
                "not longer supported\n", dp->dom_name);
}
```

### pr_usrreqs_init()

Fills in default handlers for unspecified operations (`sys/kern/uipc_domain.c:70`):

```c
static void pr_usrreqs_init(struct protosw *pr)
{
    struct pr_usrreqs *pu = pr->pr_usrreqs;

    if (pu == NULL) {
        pr->pr_usrreqs = &pru_default_notsupp;
        return;
    }

    /* Fill in default "not supported" handlers */
    if (pu->pru_abort == NULL)
        pu->pru_abort = pr_generic_notsupp;
    if (pu->pru_accept == NULL)
        pu->pru_accept = pr_generic_notsupp;
    if (pu->pru_attach == NULL)
        pu->pru_attach = pr_generic_notsupp;
    /* ... (similar for all other handlers) ... */
}
```

The default handler `pr_generic_notsupp()` returns `EOPNOTSUPP` for unsupported operations.

## Protocol Lookup

### pffindtype()

Finds a protocol by family and socket type (`sys/kern/uipc_domain.c:171`):

```c
struct protosw *pffindtype(int family, int type)
{
    struct domain *dp;
    struct protosw *pr;

    SLIST_FOREACH(dp, &domains, dom_next) {
        if (dp->dom_family == family) {
            /* Scan protocol switch table */
            for (pr = dp->dom_protosw;
                 pr < dp->dom_protoswNPROTOSW; pr++) {
                if (pr->pr_type && pr->pr_type == type)
                    return pr;
            }
        }
    }
    return NULL;
}
```

Used when creating a socket with `protocol=0` (default protocol for the type).

### pffindproto()

Finds a protocol by family, protocol number, and type (`sys/kern/uipc_domain.c:194`):

```c
struct protosw *pffindproto(int family, int protocol, int type)
{
    struct domain *dp;
    struct protosw *pr;
    struct protosw *maybe = NULL;

    if (family == 0)
        return NULL;

    SLIST_FOREACH(dp, &domains, dom_next) {
        if (dp->dom_family == family) {
            for (pr = dp->dom_protosw;
                 pr < dp->dom_protoswNPROTOSW; pr++) {
                if (pr->pr_protocol == protocol) {
                    if (pr->pr_type == type)
                        return pr;
                    if (type == SOCK_RAW && pr->pr_type == 0 &&
                        maybe == NULL)
                        maybe = pr;  /* Wildcard match for raw */
                }
            }
        }
    }
    return maybe;
}
```

Allows wildcard matching for `SOCK_RAW` sockets when exact type match fails.

## Network Message Dispatch

### Message Dispatch Model

Socket operations use LWKT messages for thread-safe protocol dispatch:

```
User Space
    │
    ▼
Socket Layer (sosend, soreceive, etc.)
    │
    ▼
so_pru_*() Wrappers (uipc_msg.c)
    │
    ├─► Build netmsg_pru_* structure
    │
    ├─► Set dispatch handler (nm_dispatch)
    │
    └─► Send to protocol's message port
            │
            ├─► lwkt_domsg()     [synchronous]
            │       └─► Wait for reply
            │
            └─► lwkt_sendmsg()   [asynchronous]
                    └─► Fire and forget
            │
            ▼
Protocol Thread
    │
    └─► nm_dispatch(netmsg)
            │
            └─► pru_handler(netmsg)
                    │
                    └─► lwkt_replymsg() [when done]
```

### Synchronous Dispatch

Most operations use synchronous dispatch (`sys/kern/uipc_msg.c:163`):

```c
int so_pru_attach(struct socket *so, int proto, struct pru_attach_info *ai)
{
    struct netmsg_pru_attach msg;
    int error;

    /* Initialize message */
    netmsg_init(&msg.base, so, &netisr_adone_rport,
                0, so->so_proto->pr_usrreqs->pru_attach);
    msg.nm_proto = proto;
    msg.nm_ai = ai;

    /* Send and wait for reply */
    error = lwkt_domsg(so->so_port, &msg.base.lmsg, 0);
    return error;
}
```

The `lwkt_domsg()` call:
1. Sends the message to `so->so_port` (protocol thread's port)
2. Blocks until the protocol handler calls `lwkt_replymsg()`
3. Returns the error code from the reply

### Asynchronous Dispatch

Performance-critical operations support async dispatch (`sys/kern/uipc_msg.c:285`):

```c
int so_pru_send(struct socket *so, int flags, struct mbuf *m,
                struct sockaddr *addr, struct mbuf *control,
                struct thread *td)
{
    struct netmsg_pru_send msg;
    int error;

    /* Initialize message */
    netmsg_init(&msg.base, so, &netisr_adone_rport,
                0, so->so_proto->pr_usrreqs->pru_send);
    msg.nm_flags = flags;
    msg.nm_m = m;
    msg.nm_addr = addr;
    msg.nm_control = control;
    msg.nm_td = td;

    /* Check if async send is allowed */
    if (so->so_proto->pr_flags & PR_ASYNC_SEND) {
        /* Async path: don't wait for completion */
        lwkt_sendmsg(so->so_port, &msg.base.lmsg);
        return 0;
    }

    /* Sync path */
    error = lwkt_domsg(so->so_port, &msg.base.lmsg, 0);
    return error;
}
```

### Direct Execution

For same-CPU optimization, direct variants bypass message passing (`sys/kern/uipc_msg.c:421`):

```c
int so_pru_attach_direct(struct socket *so, int proto,
                         struct pru_attach_info *ai)
{
    struct netmsg_pru_attach msg;
    netisr_fn_t func = so->so_proto->pr_usrreqs->pru_attach;

    /* Initialize message (no reply port needed) */
    netmsg_init(&msg.base, so, &netisr_adone_rport, 0, func);
    msg.nm_proto = proto;
    msg.nm_ai = ai;

    /* Call handler directly */
    func((netmsg_t)&msg);

    return msg.base.lmsg.ms_error;
}
```

Direct variants are used when:
- The caller is already on the protocol thread
- The operation is part of connection setup (e.g., `sonewconn()`)
- Performance is critical and serialization overhead must be avoided

### Per-Socket Async rcvd Messages

For protocols with `PR_ASYNC_RCVD`, each socket maintains a dedicated rcvd message (`sys/kern/uipc_msg.c:372`):

```c
void so_pru_rcvd_async(struct socket *so)
{
    struct netmsg_pru_rcvd *msg;

    /* Use socket's pre-allocated message */
    msg = &so->so_rcvd_msg;

    /* Only send if not already in flight */
    spin_lock(&so->so_rcvd_spin);
    if ((msg->nm_pru_flags & PRUR_ASYNC) == 0) {
        msg->nm_pru_flags |= PRUR_ASYNC;
        spin_unlock(&so->so_rcvd_spin);

        netmsg_init(&msg->base, so, &netisr_apanic_rport,
                    0, so->so_proto->pr_usrreqs->pru_rcvd);
        msg->nm_flags = 0;

        lwkt_sendmsg(so->so_port, &msg->base.lmsg);
    } else {
        spin_unlock(&so->so_rcvd_spin);
    }
}
```

This avoids allocating messages for frequent rcvd notifications in streaming protocols.

## Message Initialization

### netmsg_init()

Initializes a network message (`sys/kern/uipc_msg.c:65`):

```c
void netmsg_init(netmsg_base_t msg, struct socket *so,
                 struct lwkt_port *rport, int flags, netisr_fn_t dispatch)
{
    lwkt_initmsg(&msg->lmsg, rport, flags);
    msg->nm_dispatch = dispatch;
    msg->nm_so = so;
}
```

Parameters:
- **`msg`** - Message to initialize
- **`so`** - Associated socket
- **`rport`** - Reply port (where completion notification is sent)
- **`flags`** - LWKT message flags
- **`dispatch`** - Handler function to call on the protocol thread

### Reply Ports

Common reply ports:

- **`netisr_adone_rport`** - Async-done reply port (sets ms_error, no wakeup)
- **`netisr_apanic_rport`** - Panics if a reply is received (for fire-and-forget)
- **`curthread->td_msgport`** - Current thread's port (for sync operations)

## Control Input/Output

### kpfctlinput()

Broadcasts control input to all protocols (`sys/kern/uipc_domain.c:226`):

```c
void kpfctlinput(int cmd, struct sockaddr *sa)
{
    struct domain *dp;
    struct protosw *pr;

    SLIST_FOREACH(dp, &domains, dom_next) {
        for (pr = dp->dom_protosw;
             pr < dp->dom_protoswNPROTOSW; pr++) {
            if (pr->pr_ctlinput)
                (*pr->pr_ctlinput)(cmd, sa, NULL, NULL);
        }
    }
}
```

Used for network-wide events like interface state changes or ICMP notifications.

### kpfctlinput2()

Extended version with additional context (`sys/kern/uipc_domain.c:240`):

```c
void kpfctlinput2(int cmd, struct sockaddr *sa, void *ctlparam)
{
    struct domain *dp;
    struct protosw *pr;

    SLIST_FOREACH(dp, &domains, dom_next) {
        if (dp->dom_family != sa->sa_family)
            continue;
        for (pr = dp->dom_protosw;
             pr < dp->dom_protoswNPROTOSW; pr++) {
            if (pr->pr_ctlinput)
                (*pr->pr_ctlinput)(cmd, sa, ctlparam, NULL);
        }
    }
}
```

Filters by address family for efficiency.

### so_pr_ctloutput()

Wrapper for protocol control output (`sys/kern/uipc_msg.c:100`):

```c
int so_pr_ctloutput(struct socket *so, struct sockopt *sopt)
{
    return so->so_proto->pr_ctloutput(so, sopt);
}
```

Called from `sosetopt()`/`sogetopt()` for protocol-specific options.

## Local Domain Example

The local (Unix) domain (`sys/kern/uipc_proto.c`) demonstrates domain registration:

```c
/* Protocol switch table */
struct protosw localsw[] = {
    {
        .pr_type = SOCK_STREAM,
        .pr_domain = &localdomain,
        .pr_flags = PR_CONNREQUIRED | PR_WANTRCVD | PR_RIGHTS |
                    PR_SYNC_PORT,
        .pr_ctloutput = uipc_ctloutput,
        .pr_usrreqs = &uipc_usrreqs,
    },
    {
        .pr_type = SOCK_DGRAM,
        .pr_domain = &localdomain,
        .pr_flags = PR_ATOMIC | PR_ADDR | PR_RIGHTS | PR_SYNC_PORT,
        .pr_ctloutput = uipc_ctloutput,
        .pr_usrreqs = &uipc_usrreqs,
    },
    {
        .pr_type = SOCK_SEQPACKET,
        .pr_domain = &localdomain,
        .pr_flags = PR_ATOMIC | PR_CONNREQUIRED | PR_WANTRCVD |
                    PR_RIGHTS | PR_SYNC_PORT,
        .pr_ctloutput = uipc_ctloutput,
        .pr_usrreqs = &uipc_usrreqs,
    },
};

/* Domain structure */
struct domain localdomain = {
    .dom_family = AF_LOCAL,
    .dom_name = "local",
    .dom_init = unp_init,
    .dom_externalize = unp_externalize,
    .dom_dispose = unp_dispose,
    .dom_protosw = localsw,
    .dom_protoswNPROTOSW = &localsw[NELEM(localsw)],
};

/* Register domain via SYSINIT */
DOMAIN_SET(local);
```

Key observations:

- **`PR_SYNC_PORT`** - All local domain operations use `netisr_sync_port` for serialization
- **`PR_RIGHTS`** - File descriptor passing is supported
- **`PR_WANTRCVD`** - Stream and seqpacket protocols need rcvd notifications for flow control
- **`dom_externalize` / `dom_dispose`** - Hooks for FD passing control message handling

## Message Port Assignment

### Socket Creation

When a socket is created (`sys/kern/uipc_socket.c`):

```c
int socreate(int dom, struct socket **aso, int type, int proto,
             struct thread *td)
{
    struct protosw *prp;
    struct socket *so;

    /* Find protocol */
    prp = pffindproto(dom, proto, type);
    if (prp == NULL)
        prp = pffindtype(dom, type);
    if (prp == NULL)
        return EPROTONOSUPPORT;

    /* Allocate socket */
    so = soalloc(1, prp);

    /* Assign message port based on protocol flags */
    if (prp->pr_flags & PR_SYNC_PORT) {
        so->so_port = netisr_sync_port;
    } else {
        so->so_port = netisr_cpuport(0);  /* CPU 0 by default */
    }

    /* Attach protocol */
    error = so_pru_attach(so, proto, &ai);
    ...
}
```

### Connection Accept

For accepted connections (`sys/kern/uipc_socket2.c`):

```c
struct socket *sonewconn_faddr(struct socket *head, int connstatus,
                               struct sockaddr *faddr, boolean_t keep_ref)
{
    struct socket *so;
    struct protosw *prp = head->so_proto;

    /* Allocate socket */
    so = soalloc(1, prp);

    /* Assign port - typically use current CPU */
    if (prp->pr_flags & PR_SYNC_PORT) {
        so->so_port = netisr_sync_port;
    } else {
        so->so_port = netisr_cpuport(mycpuid);
    }
    ...
}
```

Using `mycpuid` distributes accepted connections across CPUs for better scaling.

## Initialization Timeline

```
boot
 │
 ├─► SI_SUB_KMEM: Memory allocator ready
 │
 ├─► SI_SUB_PROTO_DOMAIN: Domain registration
 │       ├─► net_add_domain(&localdomain)
 │       ├─► net_add_domain(&inetdomain)
 │       └─► ... (other domains)
 │
 ├─► SI_SUB_PRE_DRIVERS: Pre-driver init
 │
 ├─► SI_SUB_PROTO_IF: Network interface init
 │
 ├─► SI_SUB_PROTO_END: Domain initialization
 │       └─► net_init_domains()
 │               ├─► net_init_domain(&localdomain)
 │               │       ├─► pr_usrreqs_init() for each protocol
 │               │       ├─► pr->pr_init() for each protocol
 │               │       └─► dom->dom_init() [unp_init]
 │               └─► ... (other domains)
 │
 └─► System operational
```

## Error Handling

### Default Handlers

Operations without protocol support return `EOPNOTSUPP`:

```c
static void pr_generic_notsupp(netmsg_t msg)
{
    lwkt_replymsg(&msg->lmsg, EOPNOTSUPP);
}

static struct pr_usrreqs pru_default_notsupp = {
    .pru_abort = pr_generic_notsupp,
    .pru_accept = pr_generic_notsupp,
    .pru_attach = pr_generic_notsupp,
    /* ... all handlers set to pr_generic_notsupp ... */
};
```

### Protocol Lookup Failures

Socket creation returns appropriate errors:

- **`EPROTONOSUPPORT`** - Unknown protocol for the domain
- **`EAFNOSUPPORT`** - Unknown address family (domain not registered)
- **`ESOCKTNOSUPPORT`** - Socket type not supported by protocol

## See Also

- [Sockets](sockets.md) - Socket layer implementation
- [Unix Domain Sockets](unix-sockets.md) - Local domain implementation
- [LWKT Threading](../lwkt.md) - Message passing subsystem
- [Mbufs](mbufs.md) - Memory buffer management
