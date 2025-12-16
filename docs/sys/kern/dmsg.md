# Distributed Messaging (dmsg)

The DragonFly BSD kernel includes a distributed messaging protocol (dmsg) that
enables communication between kernel components across network links. This
subsystem is primarily used by HAMMER2 filesystem clustering and the xdisk
virtual block device driver.

## Overview

The dmsg protocol provides:

- Point-to-point streaming message links
- Transaction-based state management
- Mesh network topology support
- Service advertisement via SPAN protocol
- Block device and filesystem protocol extensions

```
                           Cluster Controller
                          (hammer2 service daemon)
                                   |
              +--------------------+--------------------+
              |                    |                    |
         LNK_CONN              LNK_CONN             LNK_CONN
              |                    |                    |
       +------+------+      +------+------+      +------+------+
       |             |      |             |      |             |
   HAMMER2       xdisk   HAMMER2     Client   HAMMER2      xdisk
    Mount        Device   Mount               Mount        Device
```

## Architecture

### Protocol Layers

The dmsg protocol operates in layers:

| Protocol | Code | Purpose |
|----------|------|---------|
| `DMSG_PROTO_LNK` | `0x00` | Link layer (CONN, SPAN, PING) |
| `DMSG_PROTO_DBG` | `0x01` | Debug shell access |
| `DMSG_PROTO_HM2` | `0x02` | HAMMER2 filesystem operations |
| `DMSG_PROTO_BLK` | `0x05` | Block device operations |
| `DMSG_PROTO_VOP` | `0x06` | VFS operations |

### Connection Model

```
           Node A                              Node B
    +------------------+                +------------------+
    |   kdmsg_iocom    |                |   kdmsg_iocom    |
    |                  |     Socket     |                  |
    |  msgrd_td -------|----------------|----> rcvmsg()    |
    |  msgwr_td <------|----------------|------ msgq       |
    |                  |                |                  |
    |  staterd_tree    |                |  statewr_tree    |
    |  statewr_tree    |                |  staterd_tree    |
    +------------------+                +------------------+
```

Each connection (`kdmsg_iocom`) has:
- Separate reader and writer kernel threads
- Red-black trees tracking active transactions
- Message queue for outbound messages
- Callback functions for message handling

## Key Data Structures

### Message Header

Source: `sys/sys/dmsg.h:213-229`

```c
struct dmsg_hdr {
    uint16_t    magic;          /* 00 sanity, synchro, endian */
    uint16_t    reserved02;     /* 02 */
    uint32_t    salt;           /* 04 random salt helps w/crypto */
    uint64_t    msgid;          /* 08 message transaction id */
    uint64_t    circuit;        /* 10 circuit id or 0 */
    uint64_t    link_verifier;  /* 18 link verifier */
    uint32_t    cmd;            /* 20 flags | cmd | hdr_size / ALIGN */
    uint32_t    aux_crc;        /* 24 auxillary data crc */
    uint32_t    aux_bytes;      /* 28 auxillary data length (bytes) */
    uint32_t    error;          /* 2C error code or 0 */
    uint64_t    aux_descr;      /* 30 negotiated OOB data descr */
    uint32_t    reserved38;     /* 38 */
    uint32_t    hdr_crc;        /* 3C (aligned) extended header crc */
};
```

The header is always 64 bytes and must be aligned on a 64-byte boundary.

### Command Flags

```c
#define DMSGF_CREATE    0x80000000U  /* Transaction start */
#define DMSGF_DELETE    0x40000000U  /* Transaction end */
#define DMSGF_REPLY     0x20000000U  /* Reply direction */
#define DMSGF_ABORT     0x10000000U  /* Abort request */
#define DMSGF_REVTRANS  0x08000000U  /* Opposite direction msgid */
#define DMSGF_REVCIRC   0x04000000U  /* Opposite direction circuit */
```

### I/O Communication Structure

Source: `sys/sys/dmsg.h:806-828`

```c
struct kdmsg_iocom {
    struct malloc_type  *mmsg;          /* Memory allocator */
    struct file         *msg_fp;        /* File pointer for I/O */
    thread_t            msgrd_td;       /* Reader thread */
    thread_t            msgwr_td;       /* Writer thread */
    int                 msg_ctl;        /* Wakeup flags */
    int                 msg_seq;        /* Message sequence id */
    uint32_t            flags;          /* KDMSG_IOCOMF_* */
    struct lock         msglk;          /* Lock for message queue */
    TAILQ_HEAD(, kdmsg_msg) msgq;       /* Transmit queue */
    void                *handle;        /* Caller's handle */
    void (*auto_callback)(kdmsg_msg_t *);
    int  (*rcvmsg)(kdmsg_msg_t *);
    void (*exit_func)(struct kdmsg_iocom *);
    struct kdmsg_state  state0;         /* Root state for stacking */
    struct kdmsg_state  *conn_state;    /* Active LNK_CONN state */
    struct kdmsg_state_tree staterd_tree; /* Received transactions */
    struct kdmsg_state_tree statewr_tree; /* Sent transactions */
    dmsg_lnk_conn_t     auto_lnk_conn;
    dmsg_lnk_span_t     auto_lnk_span;
};
```

### Transaction State

Source: `sys/sys/dmsg.h:735-757`

```c
struct kdmsg_state {
    RB_ENTRY(kdmsg_state) rbnode;       /* Indexed by msgid */
    struct kdmsg_state  *scan;          /* Scan check */
    struct kdmsg_state_list subq;       /* Active stacked states */
    TAILQ_ENTRY(kdmsg_state) entry;     /* On parent subq */
    struct kdmsg_iocom  *iocom;
    struct kdmsg_state  *parent;
    int                 refs;           /* Reference count */
    uint32_t            icmd;           /* Initial command */
    uint32_t            txcmd;          /* Transmit command flags */
    uint32_t            rxcmd;          /* Receive command flags */
    uint64_t            msgid;          /* Transaction ID */
    int                 flags;
    int                 error;
    void                *chain;         /* Caller's state */
    int (*func)(struct kdmsg_state *, struct kdmsg_msg *);
    union {
        void *any;
        struct hammer2_mount *hmp;
        struct xa_softc *xa_sc;
    } any;
};
```

State flags:

| Flag | Description |
|------|-------------|
| `KDMSG_STATE_SUBINSERTED` | Inserted in parent's subq |
| `KDMSG_STATE_DYNAMIC` | Dynamically allocated |
| `KDMSG_STATE_ABORTING` | Being aborted |
| `KDMSG_STATE_OPPOSITE` | Opposite direction transaction |
| `KDMSG_STATE_DYING` | Connection dying |
| `KDMSG_STATE_RBINSERTED` | Inserted in RB tree |
| `KDMSG_STATE_NEW` | Newly created, defer abort |

## Connection Protocol

### LNK_CONN

The `LNK_CONN` message establishes a connection and identifies the peer:

Source: `sys/sys/dmsg.h:410-424`

```c
struct dmsg_lnk_conn {
    dmsg_hdr_t  head;
    uuid_t      media_id;       /* Media configuration id */
    uuid_t      peer_id;        /* Unique peer uuid */
    uuid_t      reserved01;
    uint64_t    peer_mask;      /* PEER mask for SPAN filtering */
    uint8_t     peer_type;      /* DMSG_PEER_xxx */
    uint8_t     reserved02;
    uint16_t    proto_version;  /* High level protocol support */
    uint32_t    status;         /* Status flags */
    uint32_t    rnss;           /* Node's generated rnss */
    /* ... */
    char        peer_label[DMSG_LABEL_SIZE];
};
```

Peer types:

| Type | Value | Description |
|------|-------|-------------|
| `DMSG_PEER_NONE` | 0 | None |
| `DMSG_PEER_ROUTER` | 1 | Cluster controller |
| `DMSG_PEER_BLOCK` | 2 | Block device server |
| `DMSG_PEER_HAMMER2` | 3 | HAMMER2 mounted volume |
| `DMSG_PEER_CLIENT` | 63 | Client connection |

### LNK_SPAN

The `LNK_SPAN` message advertises a service over an open `LNK_CONN`:

Source: `sys/sys/dmsg.h:503-528`

```c
struct dmsg_lnk_span {
    dmsg_hdr_t  head;
    uuid_t      peer_id;
    uuid_t      pfs_id;         /* Unique PFS id */
    uint8_t     pfs_type;       /* PFS type */
    uint8_t     peer_type;      /* PEER type */
    uint16_t    proto_version;  /* Protocol version */
    uint32_t    status;         /* Status flags */
    /* ... */
    uint32_t    dist;           /* Span distance */
    uint32_t    rnss;           /* Random number sub-sort */
    union {
        uint32_t reserved03[14];
        dmsg_media_block_t block;
    } media;
    char        peer_label[DMSG_LABEL_SIZE];
    char        pfs_label[DMSG_LABEL_SIZE];
};
```

SPANs can be relayed through intermediate nodes (cluster controllers) to
build a mesh network. The `dist` field tracks hop count for path selection.

## Transaction State Machine

### Message Flow

```
Initiator                                   Responder
    |                                           |
    |  -------- CREATE ---------------------->  |
    |                                           |
    |  <------- CREATE | REPLY ---------------  |
    |                                           |
    |  -------- (data messages) ------------>  |
    |  <------- (data messages) -------------  |
    |                                           |
    |  -------- DELETE ---------------------->  |
    |                                           |
    |  <------- DELETE | REPLY ---------------  |
    |                                           |
   (transaction closed)                   (transaction closed)
```

### State Transitions

Transactions are tracked by the `txcmd` and `rxcmd` fields:

```
CREATE sent:     txcmd |= CREATE
CREATE received: rxcmd |= CREATE
DELETE sent:     txcmd |= DELETE
DELETE received: rxcmd |= DELETE

Transaction fully closed when:
    (txcmd & DELETE) && (rxcmd & DELETE)
```

### Abort Handling

Transactions can be aborted in several ways:

1. **Mid-stream abort**: Send message with `DMSGF_ABORT` flag
2. **Abort on create**: `DMSGF_ABORT | DMSGF_CREATE` for non-blocking
3. **Abort after delete**: `DMSGF_ABORT | DMSGF_DELETE` for error cleanup

## API Reference

### Initialization

```c
void kdmsg_iocom_init(kdmsg_iocom_t *iocom, void *handle,
                      uint32_t flags, struct malloc_type *mmsg,
                      int (*rcvmsg)(kdmsg_msg_t *msg));
```

Initialize an iocom structure. The `rcvmsg` callback handles received messages.

**Flags:**

| Flag | Description |
|------|-------------|
| `KDMSG_IOCOMF_AUTOCONN` | Auto-handle LNK_CONN transactions |
| `KDMSG_IOCOMF_AUTORXSPAN` | Auto-handle received LNK_SPAN |
| `KDMSG_IOCOMF_AUTOTXSPAN` | Auto-transmit LNK_SPAN |

### Connection Management

```c
void kdmsg_iocom_reconnect(kdmsg_iocom_t *iocom, struct file *fp,
                           const char *subsysname);
```

Connect or reconnect using the provided file pointer. Creates reader and
writer threads named `<subsysname>-msgrd` and `<subsysname>-msgwr`.

```c
void kdmsg_iocom_autoinitiate(kdmsg_iocom_t *iocom,
                              void (*auto_callback)(kdmsg_msg_t *msg));
```

Automatically initiate `LNK_CONN` and optionally `LNK_SPAN` transactions.

```c
void kdmsg_iocom_uninit(kdmsg_iocom_t *iocom);
```

Disconnect and clean up. Waits for all transactions to complete or abort.

### Message Operations

```c
kdmsg_msg_t *kdmsg_msg_alloc(kdmsg_state_t *state, uint32_t cmd,
                             int (*func)(kdmsg_state_t *, kdmsg_msg_t *),
                             void *data);
```

Allocate a message. If `cmd` includes `DMSGF_CREATE`, a new transaction state
is created and registered.

```c
void kdmsg_msg_write(kdmsg_msg_t *msg);
```

Queue a message for transmission.

```c
void kdmsg_msg_reply(kdmsg_msg_t *msg, uint32_t error);
```

Reply to a message and terminate the transaction.

```c
void kdmsg_msg_result(kdmsg_msg_t *msg, uint32_t error);
```

Reply to a message but keep the transaction open.

```c
void kdmsg_msg_free(kdmsg_msg_t *msg);
```

Free a message. Automatically drops the state reference.

### State Operations

```c
void kdmsg_state_reply(kdmsg_state_t *state, uint32_t error);
```

Terminate a transaction from state context.

```c
void kdmsg_state_result(kdmsg_state_t *state, uint32_t error);
```

Send a result but keep the transaction open.

## Implementation Details

### Reader Thread

Source: `sys/kern/kern_dmsg.c:324-424`

The reader thread (`kdmsg_iocom_thread_rd`) handles incoming messages:

1. Read message header from socket/pipe
2. Validate magic number and header size
3. Allocate message structure
4. Read extended header and auxiliary data
5. Call `kdmsg_msg_receive_handling()` for state machine processing

```c
static void
kdmsg_iocom_thread_rd(void *arg)
{
    kdmsg_iocom_t *iocom = arg;
    dmsg_hdr_t hdr;
    kdmsg_msg_t *msg = NULL;
    int error = 0;

    while ((iocom->msg_ctl & KDMSG_CLUSTERCTL_KILLRX) == 0) {
        /* Read and validate header */
        error = fp_read(iocom->msg_fp, &hdr, sizeof(hdr),
                        NULL, 1, UIO_SYSSPACE);
        if (error || hdr.magic != DMSG_HDR_MAGIC)
            break;

        /* Allocate and populate message */
        msg = kdmsg_msg_alloc(&iocom->state0,
                              hdr.cmd & DMSGF_BASECMDMASK,
                              NULL, NULL);
        msg->any.head = hdr;

        /* Read auxiliary data if present */
        if (msg->aux_size) {
            msg->aux_data = kmalloc(DMSG_DOALIGN(msg->aux_size),
                                    iocom->mmsg, M_WAITOK);
            error = fp_read(iocom->msg_fp, msg->aux_data, ...);
        }

        /* Process message */
        error = kdmsg_msg_receive_handling(msg);
        msg = NULL;
    }

    /* Shutdown handling... */
    lwkt_exit();
}
```

### Writer Thread

Source: `sys/kern/kern_dmsg.c:426-611`

The writer thread (`kdmsg_iocom_thread_wr`) handles outgoing messages:

1. Sleep waiting for messages in queue
2. Dequeue message and process state machine
3. Write header and auxiliary data to socket/pipe
4. Clean up state on connection termination

The writer thread is also responsible for final cleanup when the connection
terminates, simulating failures for any remaining open transactions.

### State Machine

Source: `sys/kern/kern_dmsg.c:771-1098`

The `kdmsg_state_msgrx()` function processes received message state:

- `CREATE`: Allocates new state, inserts in RB tree
- `DELETE`: Marks state for deletion
- `REPLY`: Updates state with response flags
- `ABORT`: Handles various abort scenarios

Transaction states are tracked in two RB trees:
- `staterd_tree`: Transactions initiated by the remote side
- `statewr_tree`: Transactions initiated locally

### Stacked Transactions

Transactions can be stacked by specifying a parent's `msgid` in the `circuit`
field. This creates a hierarchy:

```
state0 (root)
   |
   +-- LNK_CONN (circuit = 0)
          |
          +-- LNK_SPAN (circuit = conn.msgid)
                 |
                 +-- BLK_OPEN (circuit = span.msgid)
                        |
                        +-- BLK_READ (circuit = open.msgid)
```

When a parent transaction terminates, all child transactions are automatically
aborted by `kdmsg_simulate_failure()`.

## Block Device Protocol

The `DMSG_PROTO_BLK` protocol provides remote block device access:

### Commands

| Command | Description |
|---------|-------------|
| `DMSG_BLK_OPEN` | Open device |
| `DMSG_BLK_CLOSE` | Close device |
| `DMSG_BLK_READ` | Read data |
| `DMSG_BLK_WRITE` | Write data |
| `DMSG_BLK_FLUSH` | Flush data |
| `DMSG_BLK_FREEBLKS` | Free blocks (TRIM) |

### Read/Write Structure

```c
struct dmsg_blk_read {
    dmsg_hdr_t  head;
    uint64_t    keyid;      /* From BLK_OPEN */
    uint64_t    offset;     /* Byte offset */
    uint32_t    bytes;      /* Byte count */
    uint32_t    flags;
    uint32_t    reserved01;
    uint32_t    reserved02;
};
```

## Error Codes

| Error | Value | Description |
|-------|-------|-------------|
| `DMSG_ERR_NOSUPP` | 0x20 | Operation not supported |
| `DMSG_ERR_LOSTLINK` | 0x21 | Link lost |
| `DMSG_ERR_IO` | 0x22 | I/O error |
| `DMSG_ERR_PARAM` | 0x23 | Parameter error |
| `DMSG_ERR_CANTCIRC` | 0x24 | Cannot circuit (lost span) |

## Configuration

### Sysctl Variables

| Sysctl | Default | Description |
|--------|---------|-------------|
| `kdmsg.debug` | 1 | Debug output level |

## Usage Example

### Server Side (Receiving Connections)

```c
static int my_rcvmsg(kdmsg_msg_t *msg);

void
my_start_server(struct file *fp)
{
    kdmsg_iocom_t *iocom;

    iocom = kmalloc(sizeof(*iocom), M_MYDEV, M_WAITOK | M_ZERO);

    /* Initialize with auto-handling of CONN and SPAN */
    kdmsg_iocom_init(iocom, mydev,
                     KDMSG_IOCOMF_AUTOCONN | KDMSG_IOCOMF_AUTORXSPAN,
                     M_MYDEV, my_rcvmsg);

    /* Set up CONN info */
    iocom->auto_lnk_conn.peer_type = DMSG_PEER_BLOCK;
    snprintf(iocom->auto_lnk_conn.peer_label,
             sizeof(iocom->auto_lnk_conn.peer_label),
             "mydevice");

    /* Connect */
    kdmsg_iocom_reconnect(iocom, fp, "mydev");
    kdmsg_iocom_autoinitiate(iocom, my_auto_callback);
}

static int
my_rcvmsg(kdmsg_msg_t *msg)
{
    switch(msg->tcmd) {
    case DMSG_BLK_READ | DMSGF_CREATE | DMSGF_DELETE:
        /* Handle read request */
        /* ... */
        kdmsg_msg_reply(msg, 0);
        break;
    default:
        kdmsg_msg_reply(msg, DMSG_ERR_NOSUPP);
        break;
    }
    return 0;
}
```

### Client Side (Initiating Connections)

```c
void
my_send_read(kdmsg_state_t *span_state, uint64_t offset, uint32_t bytes)
{
    kdmsg_msg_t *msg;

    msg = kdmsg_msg_alloc(span_state,
                          DMSG_BLK_READ | DMSGF_CREATE | DMSGF_DELETE,
                          my_read_callback, NULL);
    msg->any.blk_read.offset = offset;
    msg->any.blk_read.bytes = bytes;
    kdmsg_msg_write(msg);
}

static int
my_read_callback(kdmsg_state_t *state, kdmsg_msg_t *msg)
{
    if (msg->any.head.cmd & DMSGF_DELETE) {
        if (msg->any.head.error == 0) {
            /* Success - process msg->aux_data */
        } else {
            /* Error */
        }
    }
    return 0;
}
```

## Consumers

The dmsg protocol is used by:

- **HAMMER2 Filesystem**: Cluster synchronization and distributed storage
- **xdisk Driver**: Virtual block devices over network connections
- **hammer2 Service**: Userland cluster controller daemon

## Related Documentation

- [LWKT Threading](lwkt.md) - Threading model used by dmsg
- [Synchronization](synchronization.md) - Lock mechanisms
- [Sockets](ipc/sockets.md) - Socket layer used for transport
- [Disk Subsystem](disk.md) - Block device layer

## Source Files

| File | Description |
|------|-------------|
| `sys/kern/kern_dmsg.c` | Kernel dmsg implementation |
| `sys/sys/dmsg.h` | Protocol definitions and structures |
| `sys/kern/subr_diskiocom.c` | Disk I/O over dmsg |
| `sys/dev/disk/xdisk/xdisk.c` | Virtual disk using dmsg |
