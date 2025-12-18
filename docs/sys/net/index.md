# Networking Subsystem

The DragonFly BSD networking subsystem provides the infrastructure for all
network communications, from low-level interface management to high-level
protocol processing.

## Overview

The networking code in `sys/net/` implements:

- **Network interface management** - Interface lifecycle, configuration, and I/O
- **Protocol dispatch** - Per-CPU network ISR threads for scalability
- **Routing** - Route lookup, management, and routing sockets
- **Packet filtering** - pfil hooks, pf, and IPFW firewalls
- **Traffic shaping** - ALTQ and dummynet QoS
- **Virtual interfaces** - tun, tap, VLAN, bridge, lagg
- **Tunneling** - GIF, GRE, WireGuard

## Architecture

DragonFly's networking stack has several distinguishing features:

### Per-CPU Protocol Threads

Unlike traditional BSD networking which processes packets in interrupt context,
DragonFly uses dedicated per-CPU threads for protocol processing. The network
ISR (`netisr`) system dispatches packets to the appropriate CPU based on
flow hashing.

### Message-Based Design

Network operations use LWKT messages for communication between subsystems,
enabling lock-free packet processing paths in many cases.

### Interface Model

Network interfaces are represented by `struct ifnet`, which contains:

- Interface identification (name, unit, index)
- Hardware capabilities and flags  
- Input/output queues
- Statistics counters
- Method vectors for driver operations

## Source Organization

### Core Files

| Component | Files | Description |
|-----------|-------|-------------|
| [Interface Core](interfaces.md) | `if.c`, `if_var.h` | Interface management |
| [Network ISR](netisr.md) | `netisr.c`, `netisr.h` | Protocol dispatch |
| [Routing](routing.md) | `route.c`, `rtsock.c` | Route management |
| [Ethernet](ethernet.md) | `if_ethersubr.c` | Ethernet support |
| [BPF](bpf.md) | `bpf.c` | Packet capture |
| [Packet Filter Hooks](pfil.md) | `pfil.c` | Filter framework |

### Firewalls

| Component | Directory | Description |
|-----------|-----------|-------------|
| [Packet Filter (pf)](pf.md) | `pf/` | OpenBSD firewall |
| [IPFW](ipfw.md) | `ipfw/` | FreeBSD firewall |
| [IPFW3](ipfw3.md) | `ipfw3*/` | DragonFly modular firewall |

### Traffic Shaping

| Component | Directory | Description |
|-----------|-----------|-------------|
| [ALTQ](altq.md) | `altq/` | Alternate queueing |
| [Dummynet](dummynet.md) | `dummynet/`, `dummynet3/` | Traffic shaping |

### Virtual Interfaces

| Component | Directory | Description |
|-----------|-----------|-------------|
| [TUN/TAP](tun-tap.md) | `tun/`, `tap/` | Virtual interfaces |
| [VLAN](vlan.md) | `vlan/` | 802.1Q VLANs |
| [Bridge](bridge.md) | `bridge/` | Layer 2 bridging |
| [Link Aggregation](lagg.md) | `lagg/` | LACP/failover |
| [Loopback](loopback.md) | `if_loop.c` | Loopback interface |

### Tunneling

| Component | Directory | Description |
|-----------|-----------|-------------|
| [GIF](gif.md) | `gif/` | Generic tunnel |
| [GRE](gre.md) | `gre/` | GRE tunneling |
| [WireGuard](wireguard.md) | `wg/` | WireGuard VPN |
| [6to4](stf.md) | `stf/` | IPv6 transition |

### High-Performance I/O

| Component | Directory | Description |
|-----------|-----------|-------------|
| [Netmap](netmap.md) | `netmap/` | Zero-copy packet I/O |
| [Polling](polling.md) | `if_poll.c` | Device polling |

### Serial/PPP

| Component | Directory | Description |
|-----------|-----------|-------------|
| [SPPP](sppp.md) | `sppp/` | Synchronous PPP |
| [SLIP](slip.md) | `sl/` | Serial Line IP |

### Multicast

| Component | Directory | Description |
|-----------|-----------|-------------|
| [IP Multicast](mroute.md) | `ip_mroute/` | Multicast routing |

## Key Data Structures

### struct ifnet

The central network interface structure:

```c
struct ifnet {
    char    if_xname[IFNAMSIZ];     /* external name */
    TAILQ_ENTRY(ifnet) if_link;    /* all interfaces */
    
    /* Identification */
    u_short if_index;               /* interface index */
    u_short if_type;                /* IFT_* type */
    
    /* Capabilities and flags */
    int     if_flags;               /* IFF_* flags */
    int     if_capabilities;        /* IFCAP_* */
    int     if_capenable;           /* enabled capabilities */
    
    /* I/O */
    struct  ifqueue if_snd;         /* output queue */
    int     (*if_output)();         /* output routine */
    void    (*if_input)();          /* input routine */
    int     (*if_ioctl)();          /* ioctl routine */
    void    (*if_start)();          /* initiate output */
    
    /* Statistics */
    u_long  if_ipackets;            /* packets received */
    u_long  if_opackets;            /* packets sent */
    ...
};
```

### struct route

Route lookup structure:

```c
struct route {
    struct rtentry *ro_rt;          /* resolved route */
    struct sockaddr ro_dst;         /* destination address */
};
```

### struct rtentry  

Routing table entry:

```c
struct rtentry {
    struct radix_node rt_nodes[2];  /* tree linkage */
    struct sockaddr *rt_gateway;    /* gateway address */
    u_long  rt_flags;               /* RTF_* flags */
    struct  ifnet *rt_ifp;          /* output interface */
    struct  rtentry *rt_gwroute;    /* gateway route */
    struct  rt_metrics rt_rmx;      /* route metrics */
    ...
};
```

## Packet Flow

### Receive Path

```
Hardware interrupt
    |
    v
Driver receive handler
    |
    v
ether_input() / interface input
    |
    v
netisr_dispatch() -> per-CPU protocol thread
    |
    v
ip_input() / ip6_input() / etc.
    |
    v
Protocol processing (TCP/UDP/etc.)
    |
    v
Socket receive buffer
```

### Transmit Path

```
Socket send
    |
    v
Protocol output (tcp_output, udp_output)
    |
    v
ip_output() / ip6_output()
    |
    v
Route lookup
    |
    v
ether_output() / interface output
    |
    v
Interface queue (if_snd)
    |
    v
Driver transmit (if_start)
    |
    v
Hardware
```

## Related Documentation

- [Sockets](../kern/ipc/sockets.md) - Socket layer implementation
- [Mbufs](../kern/ipc/mbufs.md) - Network buffer management
- [Protocol Dispatch](../kern/ipc/protocol-dispatch.md) - Protocol registration

## Source Reference

- Source: `sys/net/`
- Headers: `sys/net/*.h`
- Related: `sys/netinet/` (IPv4), `sys/netinet6/` (IPv6)
