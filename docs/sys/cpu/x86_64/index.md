# CPU Architecture: x86_64

The `sys/cpu/x86_64/` directory contains machine-dependent headers and utility
code for the x86-64 (AMD64/Intel 64) architecture.  Platform-specific
implementations (PC hardware) live in `sys/platform/pc64/`.

## Directory Structure

```
sys/cpu/x86_64/
    include/            Machine-dependent headers
        cpu.h           CPU definitions and macros
        cpufunc.h       Inline assembly for CPU instructions
        pmap.h          Page table entry definitions
        frame.h         Trap/interrupt frame layout
        segments.h      GDT/IDT segment descriptors
        specialreg.h    Control registers and CPUID features
        atomic.h        Atomic operations
        ...
    misc/               Assembly and utility implementations
        bzeront.s       Non-temporal zero fill
        cputimer_tsc.c  TSC-based timers
        db_disasm.c     DDB disassembler
        elf_machdep.c   ELF relocation handling
        in_cksum2.s     Optimized IP checksum
        lwbuf.c         Lightweight buffer mapping
        ...

sys/platform/pc64/x86_64/
    machdep.c           Platform initialization
    pmap.c              Page table management
    trap.c              Trap/exception handling
    mp_machdep.c        SMP support
    exception.S         Low-level exception entry
    ...
```

## Control Registers

x86-64 provides several control registers that govern CPU behavior:

### CR0 (specialreg.h)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `CR0_PE` | Protected Mode Enable |
| 1 | `CR0_MP` | Math Present (FPU) |
| 2 | `CR0_EM` | FPU Emulation |
| 3 | `CR0_TS` | Task Switched |
| 16 | `CR0_WP` | Write Protect (honor page protection in supervisor mode) |
| 29 | `CR0_NW` | Not Write-through |
| 30 | `CR0_CD` | Cache Disable |
| 31 | `CR0_PG` | Paging Enable |

### CR4 (specialreg.h)

| Bit | Name | Description |
|-----|------|-------------|
| 4 | `CR4_PSE` | Page Size Extensions (2MB pages) |
| 5 | `CR4_PAE` | Physical Address Extension |
| 7 | `CR4_PGE` | Page Global Enable |
| 9 | `CR4_OSFXSR` | OS supports FXSAVE/FXRSTOR |
| 10 | `CR4_OSXMMEXCPT` | OS handles SIMD exceptions |
| 16 | `CR4_FSGSBASE` | Enable RDFSBASE/WRFSBASE |
| 17 | `CR4_PCIDE` | Process Context Identifiers |
| 18 | `CR4_OSXSAVE` | OS supports XSAVE |
| 20 | `CR4_SMEP` | Supervisor-Mode Execution Prevention |
| 21 | `CR4_SMAP` | Supervisor-Mode Access Prevention |

### CR2 and CR3

- **CR2** - Holds the faulting linear address on a page fault
- **CR3** - Holds the physical address of the PML4 page table root

## CPU Feature Detection (cpufunc.h, specialreg.h)

CPUID instruction returns feature flags in %edx and %ecx:

**CPUID Fn0000_0001 %edx**:
- `CPUID_FPU` - x87 FPU present
- `CPUID_VME` - Virtual 8086 extensions
- `CPUID_TSC` - Time Stamp Counter
- `CPUID_MSR` - Model Specific Registers
- `CPUID_PAE` - Physical Address Extension
- `CPUID_APIC` - On-chip APIC
- `CPUID_MTRR` - Memory Type Range Registers
- `CPUID_PGE` - Page Global Enable
- `CPUID_SSE`, `CPUID_SSE2` - SIMD extensions

**CPUID Fn0000_0001 %ecx**:
- `CPUID2_SSE3`, `CPUID2_SSSE3`, `CPUID2_SSE41`, `CPUID2_SSE42`
- `CPUID2_VMX` - Intel VMX (virtualization)
- `CPUID2_AESNI` - AES instruction set
- `CPUID2_AVX` - Advanced Vector Extensions
- `CPUID2_XSAVE` - XSAVE/XRSTOR support

```c
/* cpufunc.h:134 - CPUID wrapper */
static __inline void
do_cpuid(u_int ax, u_int *p)
{
    __asm __volatile("cpuid"
        : "=a" (p[0]), "=b" (p[1]), "=c" (p[2]), "=d" (p[3])
        :  "0" (ax));
}
```

## CPU Inline Functions (cpufunc.h)

The `cpufunc.h` header provides inline assembly wrappers for privileged
instructions:

### Interrupt Control

```c
static __inline void cpu_disable_intr(void)
{
    __asm __volatile("cli" : : : "memory");
}

static __inline void cpu_enable_intr(void)
{
    __asm __volatile("sti");
}

static __inline register_t intr_disable(void)
{
    register_t rflags = read_rflags();
    cpu_disable_intr();
    return rflags;
}

static __inline void intr_restore(register_t rflags)
{
    write_rflags(rflags);
}
```

### Memory Barriers (cpufunc.h:177)

```c
/* Full memory fence */
static __inline void cpu_mfence(void)
{
    __asm __volatile("mfence" : : : "memory");
}

/* Load fence - orders reads */
static __inline void cpu_lfence(void)
{
    __asm __volatile("lfence" : : : "memory");
}

/* Store fence - orders writes (mostly compiler barrier on Intel) */
static __inline void cpu_sfence(void)
{
    __asm __volatile("" : : : "memory");
}

/* Compiler-only fence */
static __inline void cpu_ccfence(void)
{
    __asm __volatile("" : : : "memory");
}
```

### TLB Management

```c
/* Invalidate single TLB entry */
static __inline void cpu_invlpg(void *addr)
{
    __asm __volatile("invlpg %0" : : "m" (*(char *)addr) : "memory");
}

/* Flush entire TLB (reload CR3) */
static __inline void cpu_invltlb(void)
{
    load_cr3(rcr3());
}
```

### MSR Access (cpufunc.h:524)

```c
static __inline u_int64_t rdmsr(u_int msr)
{
    u_int32_t low, high;
    __asm __volatile("rdmsr" : "=a" (low), "=d" (high) : "c" (msr));
    return (low | ((u_int64_t)high << 32));
}

static __inline void wrmsr(u_int msr, u_int64_t newval)
{
    u_int32_t low = newval, high = newval >> 32;
    __asm __volatile("wrmsr" : : "a" (low), "d" (high), "c" (msr) : "memory");
}
```

### TSC (Time Stamp Counter)

```c
static __inline tsc_uclock_t rdtsc(void)
{
    u_int32_t low, high;
    __asm __volatile("rdtsc" : "=a" (low), "=d" (high));
    return (low | ((tsc_uclock_t)high << 32));
}

/* Ordered TSC read with appropriate fence */
static __inline tsc_uclock_t rdtsc_ordered(void)
{
    if (cpu_vendor_id == CPU_VENDOR_INTEL)
        cpu_lfence();
    else
        cpu_mfence();
    return rdtsc();
}
```

## Page Table Entries (pmap.h)

x86-64 uses 4-level paging with 48-bit virtual addresses:

```
PML4 (level 4) -> PDP (level 3) -> PD (level 2) -> PT (level 1) -> Page
   9 bits           9 bits          9 bits          9 bits        12 bits
```

### Page Table Entry Bits (pmap.h:67)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | `X86_PG_V` | Valid/Present |
| 1 | `X86_PG_RW` | Read/Write |
| 2 | `X86_PG_U` | User/Supervisor |
| 3 | `X86_PG_NC_PWT` | Write-Through |
| 4 | `X86_PG_NC_PCD` | Cache Disable |
| 5 | `X86_PG_A` | Accessed |
| 6 | `X86_PG_M` | Dirty (Modified) |
| 7 | `X86_PG_PS` | Page Size (2MB if set at PD level) |
| 8 | `X86_PG_G` | Global (not flushed on CR3 reload) |
| 63 | `X86_PG_NX` | No Execute |

### Page Protection Exceptions (pmap.h:126)

```c
#define PGEX_P      0x01    /* Protection violation (vs not present) */
#define PGEX_W      0x02    /* Write access */
#define PGEX_U      0x04    /* User mode access */
#define PGEX_RSV    0x08    /* Reserved bit set in PTE */
#define PGEX_I      0x10    /* Instruction fetch */
```

## Trap Frame (frame.h:55)

The `trapframe` structure captures CPU state on exception/interrupt entry:

```c
struct trapframe {
    /* Syscall arguments (rdi, rsi, rdx, rcx, r8, r9) come first */
    register_t  tf_rdi;
    register_t  tf_rsi;
    register_t  tf_rdx;
    register_t  tf_rcx;
    register_t  tf_r8;
    register_t  tf_r9;
    register_t  tf_rax;
    register_t  tf_rbx;
    register_t  tf_rbp;
    register_t  tf_r10;
    register_t  tf_r11;
    register_t  tf_r12;
    register_t  tf_r13;
    register_t  tf_r14;
    register_t  tf_r15;
    register_t  tf_xflags;      /* Software flags */
    register_t  tf_trapno;
    register_t  tf_addr;
    register_t  tf_flags;
    /* Hardware-pushed portion */
    register_t  tf_err;         /* Error code */
    register_t  tf_rip;
    register_t  tf_cs;
    register_t  tf_rflags;
    register_t  tf_rsp;
    register_t  tf_ss;
} __packed;
```

The first six registers match the System V AMD64 ABI calling convention,
allowing direct syscall argument extraction.

## Segment Descriptors (segments.h)

### Global Descriptor Table Layout (segments.h:236)

| Selector | Name | Description |
|----------|------|-------------|
| 0 | `GNULL_SEL` | Null descriptor |
| 1 | `GCODE_SEL` | Kernel 64-bit code |
| 2 | `GDATA_SEL` | Kernel data |
| 3 | `GUCODE32_SEL` | User 32-bit code (compat) |
| 4 | `GUDATA_SEL` | User data (32/64) |
| 5 | `GUCODE_SEL` | User 64-bit code |
| 6-7 | `GPROC0_SEL` | TSS (128-bit system descriptor) |
| 8 | `GUGS32_SEL` | User 32-bit GS |

### IDT Entries (segments.h:206)

```c
#define IDT_DE      0       /* Divide Error */
#define IDT_DB      1       /* Debug */
#define IDT_NMI     2       /* Non-Maskable Interrupt */
#define IDT_BP      3       /* Breakpoint */
#define IDT_OF      4       /* Overflow */
#define IDT_BR      5       /* Bound Range Exceeded */
#define IDT_UD      6       /* Invalid Opcode */
#define IDT_NM      7       /* Device Not Available */
#define IDT_DF      8       /* Double Fault */
#define IDT_TS      10      /* Invalid TSS */
#define IDT_NP      11      /* Segment Not Present */
#define IDT_SS      12      /* Stack Segment Fault */
#define IDT_GP      13      /* General Protection */
#define IDT_PF      14      /* Page Fault */
#define IDT_MF      16      /* x87 FPU Error */
#define IDT_AC      17      /* Alignment Check */
#define IDT_MC      18      /* Machine Check */
#define IDT_XF      19      /* SIMD Exception */
#define IDT_SYSCALL 0x80    /* System call vector */
```

## Atomic Operations (atomic.h)

x86-64 atomic operations use the `LOCK` prefix for SMP safety:

```c
#define MPLOCKED    "lock ; "

/* Example: atomic_add_int */
static __inline void
atomic_add_int(volatile u_int *p, u_int v)
{
    __asm __volatile(MPLOCKED "addl %1,%0"
        : "+m" (*p)
        : "iq" (v));
}
```

Supported operations (char/short/int/long variants):
- `atomic_set_*` - OR value
- `atomic_clear_*` - AND with complement
- `atomic_add_*` - Add value
- `atomic_subtract_*` - Subtract value
- `atomic_cmpset_*` - Compare and swap
- `atomic_fetchadd_*` - Fetch and add (returns old value)
- `atomic_readandclear_*` - Read and zero

Lock elision variants (`_xacquire`, `_xrelease`) use Intel TSX hints.

## Trap Handling (platform/pc64/x86_64/trap.c)

The `trap()` function dispatches exceptions based on `tf_trapno`:

| Trap | Name | Action |
|------|------|--------|
| T_PAGEFLT (12) | Page Fault | Call `trap_pfault()` -> `vm_fault()` |
| T_PROTFLT (9) | General Protection | Signal or panic |
| T_DIVIDE (18) | Divide Error | SIGFPE |
| T_BPTFLT (3) | Breakpoint | SIGTRAP or DDB |
| T_TRCTRAP (10) | Trace Trap | SIGTRAP |
| T_NMI (19) | NMI | DDB or panic |
| T_DNA (22) | Device Not Available | FPU state restore |
| T_DOUBLEFLT (23) | Double Fault | Panic |

Page faults (T_PAGEFLT) are the most common, handled by:
1. Reading faulting address from CR2
2. Calling `vm_fault()` to resolve the fault
3. Returning to retry the instruction, or sending SIGSEGV

## CPU Scheduling Interface (cpu.h)

Macros for requesting reschedule via `gd_reqflags`:

```c
#define need_lwkt_resched()  \
    atomic_set_int(&mycpu->gd_reqflags, RQF_AST_LWKT_RESCHED)
#define need_user_resched()  \
    atomic_set_int(&mycpu->gd_reqflags, RQF_AST_USER_RESCHED)
#define signotify()          \
    atomic_set_int(&mycpu->gd_reqflags, RQF_AST_SIGNAL)
```

These set bits that are checked on return from trap/syscall to trigger
context switches or signal delivery.

## SMP and Inter-Processor Communication

### TLB Shootdown

When page mappings change, other CPUs must invalidate their TLB:

```c
void smp_invltlb(void);     /* Broadcast TLB invalidation */
```

Uses IPI (Inter-Processor Interrupt) via the LAPIC.

### IPIQ (Inter-Processor Interrupt Queue)

The `need_ipiq()` macro signals pending cross-CPU work.  IPIQs are
used for TLB shootdowns, scheduler requests, and other SMP coordination.

## Meltdown/Spectre Mitigations

The `trampframe` structure (frame.h:126) supports isolated page tables
for mitigating Meltdown (CVE-2017-5754):

```c
struct trampframe {
    register_t  tr_cr2;
    register_t  tr_rax, tr_rcx, tr_rdx;
    register_t  tr_err, tr_rip, tr_cs, tr_rflags, tr_rsp, tr_ss;
    register_t  tr_pcb_rsp;         /* Trampoline stack */
    register_t  tr_pcb_flags;
    register_t  tr_pcb_cr3_iso;     /* Isolated PML4 */
    register_t  tr_pcb_cr3;         /* Full kernel PML4 */
    uint32_t    tr_pcb_spec_ctrl[2]; /* SPEC_CTRL MSR values */
    ...
};
```

On syscall/interrupt entry, the trampoline switches from the isolated
user page table to the full kernel page table.

## See Also

- [Virtual Memory Subsystem](../../vm/index.md) - Page fault handling
- [Processes and Threads](../../kern/processes.md) - Context switching
- [LWKT Scheduler](../../kern/lwkt.md) - Thread scheduling
- [Synchronization](../../kern/synchronization.md) - Locking primitives
