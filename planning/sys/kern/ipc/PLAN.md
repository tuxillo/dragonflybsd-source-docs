# Phase 7: IPC and Socket Layer Documentation Plan

This plan captures the structure, key concepts, and documentation approach for Phase 7 of the DragonFly BSD kernel documentation project.

## Overview

Phase 7 covers **~18,850 lines** across **17 source files** in six subphases:

| Subphase | Files | Lines | Description |
|----------|-------|-------|-------------|
| 7a1 | 2 files | ~3,160 | Mbufs - memory buffer system |
| 7a2 | 3 files | ~4,178 | Socket core - socket layer and buffers |
| 7a3 | 5 files | ~3,852 | Protocols - domains, Unix sockets, message-passing |
| 7a4 | 1 file | ~1,973 | Socket syscalls - user interface |
| 7b | 4 SysV files | ~3,055 | Message queues, semaphores, shared memory |
| 7c | 2 other IPC | ~2,630 | Pipes, POSIX message queues |

---

## Source Files by Subphase

### 7a1: Mbufs (Memory Buffers)

| File | Lines | Purpose |
|------|-------|---------|
| `uipc_mbuf.c` | 2755 | Mbuf allocation, manipulation, per-CPU caching |
| `uipc_mbuf2.c` | 405 | Packet tags, additional mbuf utilities |

### 7a2: Socket Core

| File | Lines | Purpose |
|------|-------|---------|
| `uipc_socket.c` | 2698 | Core socket operations (create, bind, listen, connect, send, recv, close) |
| `uipc_socket2.c` | 876 | Socket state management, wakeup, connection acceptance |
| `uipc_sockbuf.c` | 604 | Socket buffer (sockbuf) management, append, drop, flush |

### 7a3: Protocols and Unix Domain Sockets

| File | Lines | Purpose |
|------|-------|---------|
| `uipc_domain.c` | 240 | Protocol domain registration and lookup |
| `uipc_proto.c` | 98 | Local (Unix) domain protocol definitions |
| `uipc_usrreq.c` | 2571 | Unix domain socket implementation |
| `uipc_msg.c` | 791 | DragonFly message-based socket operations |
| `uipc_accf.c` | 152 | Accept filter framework |

### 7a4: Socket System Calls

| File | Lines | Purpose |
|------|-------|---------|
| `uipc_syscalls.c` | 1973 | Socket system calls (socket, bind, connect, accept, send, recv, etc.) |

### 7b: System V IPC

| File | Lines | Purpose |
|------|-------|---------|
| `sysv_ipc.c` | 69 | Common SysV IPC permission checking |
| `sysv_msg.c` | 1096 | SysV message queues |
| `sysv_sem.c` | 1163 | SysV semaphores |
| `sysv_shm.c` | 727 | SysV shared memory |

### 7c: Other IPC

| File | Lines | Purpose |
|------|-------|---------|
| `sys_pipe.c` | 1461 | Pipe implementation (VM-backed) |
| `sys_mqueue.c` | 1170 | POSIX message queues |

---

## Proposed Documentation Structure

```
docs/sys/kern/ipc/
├── index.md              # IPC overview, socket architecture, DragonFly design
├── sockets.md            # Socket core layer
├── mbufs.md              # Memory buffer system
├── protocols.md          # Protocol domains, Unix domain sockets
├── socket-syscalls.md    # Socket system calls
├── sysv-ipc.md           # System V IPC mechanisms
└── pipes.md              # Pipes and POSIX message queues
```

---

## Key Data Structures

### Socket Layer

#### `struct socket` (sys/socketvar.h)
Core socket structure:
- `so_type` - Socket type (SOCK_STREAM, SOCK_DGRAM, etc.)
- `so_options` - Socket options (SO_REUSEADDR, SO_LINGER, etc.)
- `so_state` - Connection state flags (SS_ISCONNECTED, etc.)
- `so_pcb` - Protocol Control Block (protocol-specific data)
- `so_proto` - Pointer to protocol switch (`struct protosw`)
- `so_port` - **DragonFly-specific**: LWKT message port for protocol operations
- `so_head` - Back-pointer to listening socket
- `so_incomp` / `so_comp` - Queues for incomplete/complete connections
- `so_rcv` / `so_snd` - Receive and send buffers (`struct signalsockbuf`)
- `so_refs` - Reference count

#### `struct signalsockbuf` (sys/socketvar.h)
DragonFly's enhanced socket buffer:
- `sb` - Embedded `struct sockbuf` (actual mbuf chain)
- `ssb_kq` - Kqueue information
- `ssb_mlist` - List of pending predicate messages
- `ssb_flags` - Lock/signal flags (SSB_LOCK, SSB_WAIT, SSB_WAKEUP)
- `ssb_token` - **DragonFly-specific**: LWKT token for serialization
- `ssb_timeo` / `ssb_lowat` / `ssb_hiwat` / `ssb_mbmax` - Timeout and watermarks

#### `struct sockbuf` (sys/sockbuf.h)
Low-level mbuf chain buffer:
- `sb_cc` - Actual byte count
- `sb_mbcnt` - Mbuf storage used
- `sb_mb` - Head of mbuf chain
- `sb_lastmbuf` / `sb_lastrecord` - Optimization pointers

#### `struct protosw` (sys/protosw.h)
Protocol switch entry:
- `pr_type` - Socket type handled
- `pr_domain` - Protocol domain
- `pr_protocol` - Protocol number
- `pr_flags` - Protocol characteristics (PR_ATOMIC, PR_CONNREQUIRED, PR_SYNC_PORT, PR_ASYNC_SEND)
- `pr_initport` - **DragonFly-specific**: Initial message port function
- `pr_input` / `pr_output` - Data path hooks
- `pr_usrreqs` - User request operations

#### `struct pr_usrreqs` (sys/protosw.h)
Protocol user request handlers (all take `netmsg_t`):
- `pru_abort`, `pru_accept`, `pru_attach`, `pru_bind`, `pru_connect`
- `pru_detach`, `pru_disconnect`, `pru_listen`, `pru_send`, `pru_rcvd`
- `pru_shutdown`, `pru_sockaddr`, `pru_peeraddr`
- Direct calls: `pru_sosend`, `pru_soreceive`, `pru_preconnect`, `pru_preattach`

### Mbuf System

#### `struct mbuf` (sys/mbuf.h)
Core network buffer:
- `m_next` - Next buffer in chain
- `m_nextpkt` - Next packet in queue
- `m_data` - Pointer to data
- `m_len` - Data length in this mbuf
- `m_flags` - Flags (M_PKTHDR, M_EXT, M_EOR)
- `m_type` - Data type (MT_DATA, MT_HEADER, MT_CONTROL)

#### `struct pkthdr` (sys/mbuf.h)
Packet header (when M_PKTHDR set):
- `rcvif` - Receiving interface
- `len` - Total packet length
- `csum_flags` / `csum_data` - Hardware checksum info
- `hash` - Packet hash for RSS

#### `struct m_ext` (sys/mbuf.h)
External storage descriptor:
- `ext_buf` - Start of buffer
- `ext_free` - Free function
- `ext_size` - Buffer size
- `ext_ref` - Reference function

#### `struct mbcluster` (uipc_mbuf.c)
DragonFly cluster metadata:
- `mcl_refs` - Reference count
- `mcl_data` - Actual data buffer

### Unix Domain Sockets

#### `struct unpcb` (sys/unpcb.h)
Unix PCB structure:
- `unp_socket` - Associated socket
- `unp_vnode` - Bound vnode (for named sockets)
- `unp_conn` - Connected peer
- `unp_addr` - Bound address (`struct sockaddr_un`)
- `unp_peercred` - Peer credentials
- `unp_flags` - Flags
- `unp_refcnt` - Reference count

### Protocol Domain

#### `struct domain` (sys/domain.h)
Protocol domain:
- `dom_family` - AF_xxx
- `dom_name` - Domain name
- `dom_init` - Initialization function
- `dom_externalize` - Externalize access rights (fd passing)
- `dom_dispose` - Dispose internalized rights
- `dom_protosw` - Protocol switch table start
- `dom_protoswNPROTOSW` - Protocol switch table end

### System V IPC

#### `struct ipc_perm` (sys/ipc.h)
Common IPC permission structure:
- `cuid` / `cgid` - Creator user/group
- `uid` / `gid` - Owner user/group
- `mode` - Permission bits
- `seq` - Sequence number
- `key` - User-specified key

#### `struct msqid_ds` (sys/msg.h)
Message queue descriptor:
- `msg_perm` - Permissions
- `msg_first` / `msg_last` - Message chain
- `msg_cbytes` - Bytes in use
- `msg_qnum` - Message count

#### `struct semid_pool` (sysv_sem.c)
Semaphore pool (DragonFly-specific):
- `lk` - Lockmgr lock
- `ds` - `struct semid_ds`
- `gen` - Generation counter for race detection

#### `struct shmid_ds` (sys/shm.h)
Shared memory descriptor:
- `shm_perm` - Permissions
- `shm_segsz` - Segment size
- `shm_nattch` - Attachment count
- `shm_internal` - Points to `struct shm_handle`

### Pipes

#### `struct pipe` (sys_pipe.c)
Pipe structure:
- `bufferA` / `bufferB` - Two `struct pipebuf` for bidirectional communication
- `open_count` - Open file descriptor count
- `inum` - Inode number for stat()

#### `struct pipebuf` (sys_pipe.c)
Pipe buffer (cache-line aligned):
- `rlock` / `wlock` - LWKT tokens for read/write serialization
- `rindex` / `windex` - Circular buffer indices
- `size` - Buffer size
- `buffer` - KVA of buffer
- `object` - VM object
- `state` - Buffer state flags

### POSIX Message Queues

#### `struct mqueue` (sys_mqueue.c)
Message queue:
- `mq_name` - Queue name
- `mq_mtx` - Lock
- `mq_attrib` - Attributes (maxmsg, msgsize, curmsgs)
- `mq_head[]` - Priority-based message queues (32 priorities)
- `mq_bitmap` - Fast priority lookup

---

## DragonFly-Specific Design Highlights

### 1. Message-Passing Socket Architecture

Traditional BSD uses direct function calls with locks. DragonFly uses LWKT messages:

```c
// Instead of direct calls with locks:
// error = pr_usrreqs->pru_connect(so, nam);

// DragonFly sends messages:
int so_pru_connect(struct socket *so, struct sockaddr *nam, struct thread *td)
{
    struct netmsg_pru_connect msg;
    netmsg_init(&msg.base, so, &curthread->td_msgport,
                0, so->so_proto->pr_usrreqs->pru_connect);
    msg.nm_nam = nam;
    return lwkt_domsg(so->so_port, &msg.base.lmsg, 0);
}
```

**Key message types** (net/netmsg.h):
- `struct netmsg_base` - Base message with socket pointer
- `struct netmsg_pru_send` - Send operation (flags, mbuf, addr, control)
- `struct netmsg_pru_connect` - Connect operation (address)
- `struct netmsg_so_notify` - Async event notification with predicate

**Protocol flags controlling behavior:**
- `PR_SYNC_PORT` - Synchronous execution (Unix domain sockets)
- `PR_ASYNC_SEND` - Async send supported
- `PR_ASYNC_RCVD` - Async receive notification supported

### 2. LWKT Token-Based Synchronization

Socket buffers use tokens instead of mutexes:

```c
struct signalsockbuf {
    struct lwkt_token ssb_token;  // Serializes frontend/backend
};

// Acquiring buffer lock:
if (atomic_cmpset_int(&ssb->ssb_flags, flags, flags|SSB_LOCK)) {
    lwkt_gettoken(&ssb->ssb_token);
    return 0;
}
```

**Token types used:**
- `ssb_token` - Socket buffer serialization
- `unp_token` - Global Unix domain socket token
- Pool tokens - Per-socket fine-grained locking via `lwkt_getpooltoken()`

### 3. Per-CPU Object Caching for Mbufs

DragonFly uses `objcache` for lock-free per-CPU mbuf allocation:

**Object caches created:**
- `mbuf_cache` - Plain mbufs
- `mbufphdr_cache` - Mbufs with packet headers
- `mclmeta_cache` - 2KB cluster metadata
- `mjclmeta_cache` - Jumbo cluster metadata
- `mbufcluster_cache` - Combined mbuf + cluster
- `mbufphdrcluster_cache` - Combined mbuf + pkthdr + cluster

**Per-CPU statistics:**
```c
static struct mbstat mbstat[SMP_MAXCPU] __cachealign;
```

### 4. VM-Backed Pipes

Pipes use VM objects, not simple kernel buffers:

```c
struct pipebuf {
    struct vm_object *object;  // VM object for buffer
    caddr_t buffer;            // KVA mapping
    size_t size;               // 16KB-1MB (default 32KB)
};
```

**Optimizations:**
- RDTSC-based busy-wait (`pipe_delay` = 4us) before sleeping
- Per-CPU pipe caching (`gd->gd_pipeq`)
- Cache-line aligned structures (`__cachealign`)
- Memory barriers (`cpu_lfence()`, `cpu_sfence()`)

### 5. Shared Memory Dual-Pager Support

```c
// shm_use_phys controls pager type:
if (shm_use_phys)
    object = phys_pager_alloc(NULL, size, ...);  // Wired physical
else
    object = swap_pager_alloc(NULL, size, ...);  // Swap-backed
```

### 6. Capability-Based Privilege Checking

DragonFly uses capabilities instead of simple UID=0 checks:

```c
// Instead of: if (cred->cr_uid == 0)
// DragonFly uses:
caps_priv_check(cred, SYSCAP_RESTRICTEDROOT);
```

### 7. Jail Support

All IPC mechanisms respect jail restrictions:
- `PRISON_CAP_SYS_SYSVIPC` - Controls SysV IPC access

---

## Key Functions by File

### uipc_socket.c - Core Socket Operations

| Function | Purpose |
|----------|---------|
| `soalloc()` | Allocate socket structure |
| `socreate()` | Create socket (domain, type, protocol) |
| `sobind()` | Bind to address |
| `solisten()` | Mark as accepting connections |
| `soconnect()` | Initiate connection |
| `soaccept()` | Accept incoming connection |
| `sodisconnect()` | Disconnect |
| `soclose()` | Close socket |
| `sofree()` | Free when refcount drops |
| `sosend()` | Generic send |
| `sosendudp()` / `sosendtcp()` | Protocol-optimized send |
| `soreceive()` / `sorecvtcp()` | Receive |
| `soshutdown()` | Shutdown half |
| `sosetopt()` / `sogetopt()` | Socket options |

### uipc_socket2.c - Socket State

| Function | Purpose |
|----------|---------|
| `soisconnecting()` / `soisconnected()` | Connection state transitions |
| `soisdisconnecting()` / `soisdisconnected()` | Disconnection states |
| `sonewconn()` | Create socket for incoming connection |
| `sowakeup()` | Wake waiters on buffer |
| `ssb_wait()` / `_ssb_lock()` | Buffer wait/lock |
| `soreserve()` | Reserve buffer space |

### uipc_sockbuf.c - Buffer Management

| Function | Purpose |
|----------|---------|
| `sbappend()` | Append mbuf chain |
| `sbappendstream()` | Optimized TCP append |
| `sbappendrecord()` | Append as new record |
| `sbappendaddr()` | Append with sender address |
| `sbdrop()` | Drop from front |
| `sbflush()` | Flush all data |

### uipc_mbuf.c - Mbuf Operations

| Function | Purpose |
|----------|---------|
| `m_get()` / `m_gethdr()` | Allocate mbuf |
| `m_getcl()` / `m_getjcl()` | Allocate mbuf + cluster |
| `m_free()` / `m_freem()` | Free mbuf/chain |
| `m_copym()` | Read-only copy (shares clusters) |
| `m_dup()` | Deep copy |
| `m_pullup()` | Make first N bytes contiguous |
| `m_copydata()` | Copy data to buffer |
| `m_adj()` | Trim bytes |

### uipc_domain.c - Domain Registration

| Function | Purpose |
|----------|---------|
| `net_add_domain()` | Register protocol domain |
| `net_init_domain()` | Initialize domain and protocols |
| `pffindtype()` | Find protocol by socket type |
| `pffindproto()` | Find protocol by number |

### uipc_usrreq.c - Unix Domain Sockets

| Function | Purpose |
|----------|---------|
| `unp_attach()` | Attach pcb to socket |
| `unp_bind()` | Bind to filesystem path |
| `unp_connect()` | Connect to peer |
| `uipc_send()` | Send data/fds |
| `unp_internalize()` | Convert fds to file pointers (send) |
| `unp_externalize()` | Convert file pointers to fds (recv) |
| `unp_gc()` | Garbage collect orphaned fds |

### uipc_msg.c - Message Operations

| Function | Purpose |
|----------|---------|
| `so_pru_connect()` | Send connect message (sync) |
| `so_pru_connect_async()` | Send connect message (async) |
| `so_pru_send()` | Send data message (sync) |
| `so_pru_send_async()` | Send data message (async) |
| `so_pru_abort_direct()` | Direct abort (no message) |
| `netmsg_so_notify()` | Predicate-based notification |

### uipc_syscalls.c - System Calls

| Syscall | Function | Purpose |
|---------|----------|---------|
| `socket` | `kern_socket()` | Create socket |
| `bind` | `kern_bind()` | Bind to address |
| `listen` | `kern_listen()` | Listen for connections |
| `accept` | `kern_accept()` | Accept connection |
| `connect` | `kern_connect()` | Connect to peer |
| `send/sendto/sendmsg` | `kern_sendmsg()` | Send data |
| `recv/recvfrom/recvmsg` | `kern_recvmsg()` | Receive data |
| `shutdown` | `kern_shutdown()` | Shutdown socket |
| `socketpair` | `kern_socketpair()` | Create socket pair |
| `sendfile` | `kern_sendfile()` | Zero-copy file send |
| `getsockopt/setsockopt` | `kern_getsockopt()` | Socket options |

### sysv_msg.c - Message Queues

| Syscall | Function | Purpose |
|---------|----------|---------|
| `msgget` | `sys_msgget()` | Create/get queue |
| `msgsnd` | `sys_msgsnd()` | Send message |
| `msgrcv` | `sys_msgrcv()` | Receive message |
| `msgctl` | `sys_msgctl()` | Control operations |

### sysv_sem.c - Semaphores

| Syscall | Function | Purpose |
|---------|----------|---------|
| `semget` | `sys_semget()` | Create/get semaphore set |
| `semop` | `sys_semop()` | Perform operations |
| `semctl` | `sys___semctl()` | Control operations |

### sysv_shm.c - Shared Memory

| Syscall | Function | Purpose |
|---------|----------|---------|
| `shmget` | `sys_shmget()` | Create/get segment |
| `shmat` | `sys_shmat()` | Attach segment |
| `shmdt` | `sys_shmdt()` | Detach segment |
| `shmctl` | `sys_shmctl()` | Control operations |

### sys_pipe.c - Pipes

| Syscall | Function | Purpose |
|---------|----------|---------|
| `pipe` | `sys_pipe()` | Create pipe |
| `pipe2` | `sys_pipe2()` | Create pipe with flags |

| Internal | Purpose |
|----------|---------|
| `pipe_read()` | Read from pipe |
| `pipe_write()` | Write to pipe |
| `pipespace()` | Allocate VM-backed buffer |

### sys_mqueue.c - POSIX Message Queues

| Syscall | Function | Purpose |
|---------|----------|---------|
| `mq_open` | `sys_mq_open()` | Open/create queue |
| `mq_close` | `sys_mq_close()` | Close descriptor |
| `mq_send` | `sys_mq_send()` | Send message |
| `mq_receive` | `sys_mq_receive()` | Receive message |
| `mq_notify` | `sys_mq_notify()` | Register notification |
| `mq_unlink` | `sys_mq_unlink()` | Remove queue |

---

## Documentation Approach

### index.md - IPC Overview (~400 lines)
- IPC mechanisms in DragonFly: sockets, SysV IPC, pipes, POSIX mqueues
- Socket architecture overview
- DragonFly's message-passing design philosophy
- How IPC relates to rest of kernel (VFS, VM, processes)

### sockets.md - Socket Core (~600 lines)
- `struct socket` and `struct signalsockbuf` in detail
- Socket lifecycle: create → bind → listen → accept/connect → send/recv → close
- Socket states and transitions
- Buffer management: `struct sockbuf`, watermarks, preallocation
- Reference counting and `sofree()`
- DragonFly async/sync duality

### mbufs.md - Memory Buffers (~500 lines)
- Mbuf structure and types
- Mbuf chains and packets
- External storage (clusters)
- Per-CPU object caching
- Allocation functions (m_get, m_getcl, etc.)
- Manipulation (m_pullup, m_copydata, m_adj)
- Packet tags

### protocols.md - Protocol Framework (~600 lines)
- Protocol domains and `struct domain`
- Protocol switch (`struct protosw`)
- User request handlers (`struct pr_usrreqs`)
- Message-based operations (`uipc_msg.c`)
- Unix domain sockets in detail
- File descriptor passing
- Accept filters

### socket-syscalls.md - System Calls (~400 lines)
- Socket creation and binding
- Connection establishment (connect, listen, accept)
- Data transfer (send, recv variants)
- sendfile() implementation
- Socket options
- Shutdown and close

### sysv-ipc.md - System V IPC (~500 lines)
- Common permission model
- Message queues: data structures, segmented storage
- Semaphores: pool tokens, generation counters, undo
- Shared memory: VM integration, dual-pager support
- DragonFly-specific: token synchronization, jail support

### pipes.md - Pipes and POSIX Mqueues (~400 lines)
- Pipe architecture: VM-backed circular buffers
- Full-duplex design (bufferA/bufferB)
- Optimizations: busy-wait, per-CPU caching
- POSIX message queues: priority queues, notification

---

## Estimated Documentation Sizes

| File | Est. Lines | Complexity |
|------|------------|------------|
| `index.md` | 300-400 | Medium |
| `sockets.md` | 500-600 | High |
| `mbufs.md` | 400-500 | High |
| `protocols.md` | 500-600 | High |
| `socket-syscalls.md` | 300-400 | Medium |
| `sysv-ipc.md` | 400-500 | Medium |
| `pipes.md` | 300-400 | Medium |
| **Total** | **2700-3400** | |

---

## Suggested Execution Order

1. **index.md** - Establish overall architecture
2. **mbufs.md** - Foundation for understanding socket data flow
3. **sockets.md** - Core socket layer
4. **protocols.md** - Protocol framework and Unix domain
5. **socket-syscalls.md** - User-facing interface
6. **sysv-ipc.md** - Independent from sockets
7. **pipes.md** - Independent from sockets

This order builds understanding progressively: mbufs are needed to understand socket buffers, socket core is needed before protocols, etc.

---

## Cross-References to Other Documentation

- **LWKT** (`docs/sys/kern/lwkt.md`) - Tokens, message passing
- **Synchronization** (`docs/sys/kern/synchronization.md`) - Locks, spinlocks
- **Memory** (`docs/sys/kern/memory.md`) - Kernel memory allocation
- **Processes** (`docs/sys/kern/processes.md`) - Credentials, file descriptors
- **VFS** (`docs/sys/kern/vfs/`) - File operations, vnodes (for Unix domain sockets)
