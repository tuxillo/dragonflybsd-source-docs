# Network ISR (netisr)

!!! note "Documentation Status"
    This page is a stub. Detailed documentation will be added following
    the [reading plan](../../../planning/sys/net/PLAN.md).

## Overview

The Network ISR (Interrupt Service Routine) subsystem provides DragonFly BSD's
scalable packet dispatch mechanism. Unlike traditional BSD systems that process
packets in interrupt context, DragonFly uses per-CPU kernel threads for
protocol processing.

## Architecture

### Per-CPU Protocol Threads

Each CPU has dedicated threads for network protocol processing:

- Packets are dispatched to CPUs based on flow hashing
- Enables parallel processing of independent flows
- Reduces lock contention in protocol stacks

### Message-Based Dispatch

Network operations use LWKT messages:

- `netmsg` structures carry packet and control information
- Asynchronous dispatch to target CPU
- Ordered delivery within a flow

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `netisr.c` | 846 | Network ISR implementation |
| `netisr.h` | 239 | Public definitions |
| `netisr2.h` | 239 | Extended definitions |
| `netmsg.h` | 341 | Message structures |
| `netmsg2.h` | 102 | Extended message definitions |

## Key Functions

```c
/* Protocol registration */
void netisr_register(int proto, netisr_fn_t func, netisr_hashfn_t hashfn);

/* Packet dispatch */
void netisr_dispatch(int proto, struct mbuf *m);
void netisr_queue(int proto, struct mbuf *m);

/* CPU targeting */
void netisr_cpuport(int proto, int cpu);
```

## Protocol Numbers

Common `NETISR_*` protocol identifiers:

| Protocol | Description |
|----------|-------------|
| `NETISR_IP` | IPv4 |
| `NETISR_ARP` | ARP |
| `NETISR_IP6` | IPv6 |
| `NETISR_ETHER` | Ethernet |

## Flow Hashing

Packets are distributed across CPUs using:

- Source/destination IP addresses
- Source/destination ports (TCP/UDP)
- Toeplitz hash for RSS-capable hardware

## Related Documentation

- [LWKT](../kern/lwkt.md) - Lightweight kernel threads
- [Interfaces](interfaces.md) - Network interface layer

## Source Reference

- Source: `sys/net/netisr.c`
- Headers: `sys/net/netisr.h`, `sys/net/netmsg.h`
