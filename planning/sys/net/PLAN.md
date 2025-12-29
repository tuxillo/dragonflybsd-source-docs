# sys/net Documentation Plan

This document outlines the reading and documentation plan for the DragonFly BSD
networking subsystem located in `sys/net/`.

## Overview

The `sys/net/` directory contains the core networking infrastructure including
network interface management, routing, packet filtering, and various network
protocols and pseudo-devices across base files and subdirectories.

## Directory Structure

### Core Files
Base networking infrastructure in `sys/net/`:

| File | Description |
|------|-------------|
| `if.c` | Network interface core |
| `if.h` / `if_var.h` | Interface definitions and structures |
| `if_ethersubr.c` | Ethernet support routines |
| `route.c` | Routing table management |
| `route.h` | Routing structures |
| `rtsock.c` | Routing socket interface |
| `radix.c` / `radix.h` | Radix tree for routing |
| `netisr.c` / `netisr.h` | Network ISR dispatch |
| `bpf.c` / `bpf_filter.c` | Berkeley Packet Filter |
| `if_poll.c` | Interface polling |
| `pfil.c` | Packet filter hooks |
| `if_clone.c` | Interface cloning |
| `if_loop.c` | Loopback interface |
| `if_media.c` | Media selection |
| `raw_usrreq.c` / `raw_cb.c` | Raw socket support |
| `toeplitz.c` | Toeplitz hash (RSS) |
| `zlib.c` | Compression library |

### Subdirectories

| Directory | Description |
|-----------|-------------|
| `pf/` | Packet Filter firewall (OpenBSD port) |
| `altq/` | Alternate Queueing (QoS/traffic shaping) |
| `netmap/` | High-performance packet I/O |
| `ipfw/` | IP Firewall (FreeBSD legacy) |
| `wg/` | WireGuard VPN |
| `bridge/` | Network bridging |
| `sppp/` | Synchronous PPP |
| `lagg/` | Link aggregation |
| `ip_mroute/` | IP multicast routing |
| `ipfw3_basic/` | IPFW3 basic modules |
| `dummynet3/` | Traffic shaping (new) |
| `dummynet/` | Traffic shaping (legacy) |
| `ipfw3/` | IPFW3 core |
| `ip6fw/` | IPv6 firewall |
| `vlan/` | VLAN support |
| `ipfw3_nat/` | IPFW3 NAT |
| `tap/` | TAP virtual interface |
| `tun/` | TUN virtual interface |
| `sl/` | SLIP |
| `gre/` | GRE tunneling |
| `gif/` | Generic tunnel interface |
| `ppp_layer/` | PPP layer |
| `stf/` | 6to4 tunnel |
| `accf_http/` | HTTP accept filter |
| `ipfw3_layer4/` | IPFW3 layer 4 |
| `ipfw3_layer2/` | IPFW3 layer 2 |
| `disc/` | Discard interface |
| `accf_data/` | Data accept filter |

---

## Reading Phases

### Phase 1: Network Interface Core
**Goal**: Understand interface management and data structures.
**Files**:
- `sys/net/if.h` - Interface constants and ioctl definitions
- `sys/net/if_var.h` - `struct ifnet` and related structures
- `sys/net/if.c` - Interface management implementation
- `sys/net/if_clone.c` - Interface cloning mechanism
- `sys/net/ifq_var.h` - Interface queue definitions

**Key concepts**:
- `struct ifnet` - network interface structure
- Interface lifecycle (attach, detach)
- Interface flags and capabilities
- Interface queue management
- Cloneable interfaces

### Phase 2: Network ISR and Message Passing
**Goal**: Understand DragonFly's network ISR dispatch system.
**Files**:
- `sys/net/netisr.h` - Network ISR definitions
- `sys/net/netisr2.h` - Extended definitions
- `sys/net/netisr.c` - Network ISR implementation
- `sys/net/netmsg.h` - Network message structures
- `sys/net/netmsg2.h` - Extended message definitions

**Key concepts**:
- Per-CPU protocol threads
- Network message dispatch
- Protocol registration
- Packet flow between CPUs

### Phase 3: Routing Subsystem
**Goal**: Understand routing table management.
**Files**:
- `sys/net/route.h` - Routing structures
- `sys/net/route.c` - Routing implementation
- `sys/net/rtsock.c` - Routing socket interface
- `sys/net/radix.h` - Radix tree definitions
- `sys/net/radix.c` - Radix tree implementation

**Key concepts**:
- `struct rtentry` - route entry
- Radix tree lookup
- Route metrics and flags
- Routing socket messages (RTM_*)
- Route cloning and redirect

### Phase 4: Ethernet and Link Layer
**Goal**: Understand Ethernet frame handling.
**Files**:
- `sys/net/ethernet.h` - Ethernet definitions
- `sys/net/if_ethersubr.c` - Ethernet support routines
- `sys/net/if_arp.h` - ARP definitions
- `sys/net/if_dl.h` - Data link structures
- `sys/net/if_llc.h` - LLC definitions
- `sys/net/if_media.h` / `if_media.c` - Media selection

**Key concepts**:
- Ethernet frame format
- `ether_output()` / `ether_input()`
- ARP integration
- Media types and selection

### Phase 5: Berkeley Packet Filter
**Goal**: Understand BPF for packet capture.
**Files**:
- `sys/net/bpf.h` - BPF definitions
- `sys/net/bpfdesc.h` - BPF descriptor
- `sys/net/bpf.c` - BPF implementation
- `sys/net/bpf_filter.c` - BPF filter machine
- `sys/net/dlt.h` - Data link types

**Key concepts**:
- BPF filter programs
- Packet capture tap points
- Buffer management
- Zero-copy optimizations

### Phase 6: Packet Filter Hooks and Polling
**Goal**: Understand packet filter framework and polling.
**Files**:
- `sys/net/pfil.h` - Packet filter hooks
- `sys/net/pfil.c` - pfil implementation
- `sys/net/if_poll.h` - Polling definitions
- `sys/net/if_poll.c` - Device polling

**Key concepts**:
- pfil hook registration
- Input/output packet filtering
- Device polling vs interrupts
- Per-CPU polling

### Phase 7: Virtual Interfaces
**Goal**: Document virtual network interfaces.
**Directories**:
- `sys/net/tun/` - TUN device (IP tunneling)
- `sys/net/tap/` - TAP device (Ethernet tunneling)
- `sys/net/vlan/` - 802.1Q VLAN support
- `sys/net/if_loop.c` - Loopback interface
- `sys/net/disc/` - Discard interface

**Key concepts**:
- Virtual interface implementation
- User-space integration
- VLAN tagging/untagging

### Phase 8: Tunneling Protocols
**Goal**: Document tunnel interfaces.
**Directories**:
- `sys/net/gif/` - Generic tunnel interface
- `sys/net/gre/` - GRE tunneling
- `sys/net/stf/` - 6to4 tunnel

**Key concepts**:
- Encapsulation/decapsulation
- Tunnel MTU handling
- IPv4/IPv6 tunneling

### Phase 9: PPP and Serial
**Goal**: Document PPP and serial networking.
**Directories**:
- `sys/net/sppp/` - Synchronous PPP
- `sys/net/sl/` - SLIP
- `sys/net/ppp_layer/` - PPP layer

**Key concepts**:
- PPP state machine
- LCP/IPCP negotiation
- Compression (VJ)

### Phase 10: Link Aggregation and Bridging
**Goal**: Document layer 2 features.
**Directories**:
- `sys/net/bridge/` - Network bridging
- `sys/net/lagg/` - Link aggregation

**Key concepts**:
- Bridge forwarding
- Spanning tree protocol
- LACP aggregation
- Load balancing policies

### Phase 11: Packet Filter (pf)
**Goal**: Document OpenBSD's pf firewall.
**Directory**:
- `sys/net/pf/` - Complete pf implementation

**Key concepts**:
- Rule evaluation
- State tracking
- NAT/BINAT/RDR
- Anchors and tables
- pfsync for HA

### Phase 12: IPFW and IPFW3
**Goal**: Document IP firewall implementations.
**Directories**:
- `sys/net/ipfw/` - Legacy IPFW
- `sys/net/ipfw3/` - IPFW3 core
- `sys/net/ipfw3_basic/` - Basic modules
- `sys/net/ipfw3_layer2/` - Layer 2 rules
- `sys/net/ipfw3_layer4/` - Layer 4 rules
- `sys/net/ipfw3_nat/` - NAT support
- `sys/net/ip6fw/` - IPv6 firewall

**Key concepts**:
- Rule chains
- Dynamic rules
- Stateful filtering
- IPFW3 modular architecture

### Phase 13: Traffic Shaping (ALTQ/Dummynet)
**Goal**: Document QoS and traffic shaping.
**Directories**:
- `sys/net/altq/` - ALTQ framework
- `sys/net/dummynet/` - Legacy dummynet
- `sys/net/dummynet3/` - New dummynet

**Key concepts**:
- Queueing disciplines (CBQ, HFSC, PRIQ)
- Bandwidth limiting
- Delay and loss simulation
- Pipe/queue configuration

### Phase 14: Netmap
**Goal**: Document high-performance packet I/O.
**Directory**:
- `sys/net/netmap/` - Netmap framework

**Key concepts**:
- Zero-copy packet I/O
- Ring buffer architecture
- VALE software switch
- Driver integration

### Phase 15: WireGuard
**Goal**: Document WireGuard VPN implementation.
**Directory**:
- `sys/net/wg/` - WireGuard implementation

**Key concepts**:
- Cryptokey routing
- Noise protocol framework
- Peer management
- Timer-based rekeying

### Phase 16: Multicast Routing
**Goal**: Document IP multicast routing.
**Directory**:
- `sys/net/ip_mroute/` - Multicast routing

**Key concepts**:
- IGMP snooping
- Multicast forwarding cache
- PIM integration

### Phase 17: Miscellaneous
**Goal**: Document remaining components.
**Files/Directories**:
- `sys/net/raw_usrreq.c` / `raw_cb.c` - Raw sockets
- `sys/net/toeplitz.c` - RSS hashing
- `sys/net/accf_data/` - Accept filter (data)
- `sys/net/accf_http/` - Accept filter (HTTP)
- `sys/net/net_osdep.c` - OS dependencies

---

## Documentation Priority

### High Priority (Core networking)
1. Network interface core (`if.c`, `if_var.h`)
2. Network ISR (`netisr.c`)
3. Routing subsystem (`route.c`, `rtsock.c`)
4. Ethernet support (`if_ethersubr.c`)

### Medium Priority (Common features)
5. BPF (`bpf.c`)
6. Virtual interfaces (tun, tap, vlan)
7. pf firewall
8. Bridge and lagg

### Lower Priority (Specialized)
9. IPFW/IPFW3
10. ALTQ/Dummynet
11. Netmap
12. WireGuard
13. Tunneling (gif, gre, stf)
14. PPP/SLIP
15. Multicast routing

---

## Cross-References

### Kernel Dependencies
- `sys/kern/uipc_socket.c` - Socket layer
- `sys/kern/uipc_mbuf.c` - mbuf management
- `sys/netinet/` - IPv4 protocol stack
- `sys/netinet6/` - IPv6 protocol stack

### Related Documentation
- `docs/sys/kern/ipc/sockets.md` - Socket implementation
- `docs/sys/kern/ipc/mbufs.md` - mbuf documentation
