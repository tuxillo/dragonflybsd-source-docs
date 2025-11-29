# LWKT Threading

*Documentation in progress. This subsystem is Phase 0 in the kern/ reading plan.*

## Overview

LWKT (Lightweight Kernel Threading) is DragonFly BSD's unique message-passing based concurrency model.

## Key Files

- `lwkt_thread.c` — Thread management
- `lwkt_msgport.c` — Message ports and message passing
- `lwkt_token.c` — Serializing tokens
- `lwkt_ipiq.c` — Inter-processor interrupt queues
- `lwkt_serialize.c` — Serialization helpers

## To Be Documented

- Message passing architecture
- Token-based synchronization
- Inter-processor communication
- Thread lifecycle
- Integration with scheduler

*See `planning/sys/kern/PLAN.md` Phase 0 for reading order.*
