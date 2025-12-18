# Network Interfaces

!!! note "Documentation Status"
    This page is a stub. Detailed documentation will be added following
    the [reading plan](../../../planning/sys/net/PLAN.md).

## Overview

Network interface management is the foundation of the DragonFly BSD networking
stack. The `if.c` and related files implement interface lifecycle management,
configuration, and the interface abstraction layer.

## Key Components

### struct ifnet

The central interface structure containing:

- Interface identification (name, index, type)
- Capability flags and enabled features
- Input/output method vectors
- Transmit queue management
- Statistics counters

### Interface Operations

- **Attach/Detach** - Interface registration and removal
- **Ioctl** - Configuration interface (SIOC* commands)
- **Input/Output** - Packet handling methods
- **Cloning** - Dynamic interface creation (tun, tap, vlan, etc.)

## Source Files

| File | Lines | Description |
|------|-------|-------------|
| `if.c` | 4,208 | Interface management core |
| `if.h` | 391 | Public interface definitions |
| `if_var.h` | 1,004 | Internal structures |
| `if_clone.c` | 405 | Interface cloning |
| `if_clone.h` | 132 | Clone definitions |
| `ifq_var.h` | 639 | Interface queue definitions |
| `if_types.h` | 253 | Interface type constants |

## Key Functions

```c
/* Interface lifecycle */
void if_attach(struct ifnet *ifp);
void if_detach(struct ifnet *ifp);

/* Interface lookup */
struct ifnet *ifunit(const char *name);
struct ifnet *ifindex2ifnet(int idx);

/* Output */
int if_output(struct ifnet *ifp, struct mbuf *m, ...);

/* Cloning */
int if_clone_create(const char *name, int unit);
int if_clone_destroy(const char *name);
```

## Interface Flags

Common `IFF_*` flags:

| Flag | Description |
|------|-------------|
| `IFF_UP` | Interface is up |
| `IFF_BROADCAST` | Supports broadcast |
| `IFF_LOOPBACK` | Loopback interface |
| `IFF_RUNNING` | Resources allocated |
| `IFF_PROMISC` | Promiscuous mode |
| `IFF_MULTICAST` | Supports multicast |

## Related Documentation

- [Ethernet](ethernet.md) - Ethernet-specific support
- [Loopback](loopback.md) - Loopback interface
- [VLAN](vlan.md) - VLAN interfaces

## Source Reference

- Source: `sys/net/if.c`
- Headers: `sys/net/if.h`, `sys/net/if_var.h`
