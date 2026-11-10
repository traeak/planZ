//! Machine-dependent data structures.
//! from 9/pc64/dat.h, 9/pc/io.h (vectors, Vctl) and the PMach part of
//! 9/port/portdat.h
//!
//! DIFF: `m` and `up` are not pinned in R15/R14; m() reads the Mach
//! pointer through GS, exactly where the C kernel's trap entry finds it.

const mem = @import("mem.zig");
const portdat = @import("../../port/portdat.zig");

pub const Proc = portdat.Proc;

pub const Label = extern struct {
    sp: usize = 0,
    pc: usize = 0,
};

/// from /amd64/include/ureg.h; the layout is ABI (notes, /proc/n/regs).
pub const Ureg = extern struct {
    ax: u64,
    bx: u64,
    cx: u64,
    dx: u64,
    si: u64,
    di: u64,
    bp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    ds: u16,
    es: u16,
    fs: u16,
    gs: u16,

    type: u64,
    @"error": u64, // error code (or zero)
    pc: u64, // pc
    cs: u64, // old context
    flags: u64, // old flags
    sp: u64, // sp
    ss: u64, // old stack segment
};

comptime {
    if (@sizeOf(Ureg) != 23 * 8) @compileError("Ureg layout");
    if (@offsetOf(Ureg, "type") != 16 * 8) @compileError("Ureg layout");
}

pub const Confmem = extern struct {
    base: usize = 0,
    npage: usize = 0,
    kbase: usize = 0,
    klimit: usize = 0,
};

pub const Conf = struct {
    nmach: u32 = 0, // processors
    nproc: u32 = 0, // processes
    monitor: u32 = 0, // has monitor?
    npage: usize = 0, // total physical pages of memory
    upages: usize = 0, // user page pool
    nimage: u32 = 0, // number of page cache image headers
    nswap: u32 = 0, // number of swap pages
    nswppo: i32 = 0, // max # of pageouts per segment pass
    copymode: u32 = 0, // 0 is copy on write, 1 is copy on reference
    ialloc: usize = 0, // max interrupt time allocation in bytes
    pipeqsize: u32 = 0, // size in bytes of pipe queues
    nuart: i32 = 0, // number of uart devices
    mem: [64]Confmem = @splat(.{}), // physical memory
};

pub var conf: Conf = .{};

/// 0 terminal, 1 cpu server; the "port" section of the kernel config.
pub var cpuserver: bool = false;

pub const Segdesc = extern struct {
    d0: u32 = 0,
    d1: u32 = 0,
};

pub const Tss = extern struct {
    _0_: u32 = 0,
    rsp0: [2]u32 = .{ 0, 0 },
    rsp1: [2]u32 = .{ 0, 0 },
    rsp2: [2]u32 = .{ 0, 0 },
    _28_: [2]u32 = .{ 0, 0 },
    ist: [14]u32 = @splat(0),
    _92_: [5]u16 = @splat(0),
    iomap: u16 = 0,
};

comptime {
    if (@sizeOf(Tss) != 104) @compileError("Tss layout");
}

pub const Perf = extern struct {
    intrts: u32 = 0, // time of last interrupt
    inintr: u32 = 0, // time since last clock tick in interrupt handlers
    avg_inintr: u32 = 0, // avg time per clock tick in interrupt handlers
    inidle: u32 = 0, // time since last clock tick in idle loop
    avg_inidle: u32 = 0, // avg time per clock tick in idle loop
    last: u32 = 0, // value of perfticks() at last clock tick
    period: u32 = 0, // perfticks() per clock tick
};

pub const Mach = extern struct {
    // The first three fields are known to the assembly in l.zig.
    machno: i32 = 0, // physical id of processor
    splpc: usize = 0, // pc of last caller to splhi
    proc: ?*Proc = null, // current process on this processor

    // PMach
    readied: ?*Proc = null, // for runproc
    sched: Label = .{}, // scheduler wakeup
    ticks: u32 = 0, // of the clock since boot time
    schedticks: u32 = 0, // next forced context switch
    cs: i32 = 0,
    syscall: i32 = 0,
    load: i32 = 0,
    intr: i32 = 0,
    ilockdepth: i32 = 0,
    pfault: u32 = 0,
    tlbflush: u32 = 0,
    perf: Perf = .{}, // performance counters
    cyclefreq: u64 = 0, // Frequency of user readable cycle counter

    tscticks: u64 = 0,
    spuriousintr: u32 = 0,
    lastintr: i32 = 0,

    loopconst: i32 = 0,
    delaylcycles: i32 = 0,
    cpumhz: i32 = 0,
    cpuhz: u64 = 0,

    cpuidax: u32 = 0,
    cpuidcx: u32 = 0,
    cpuiddx: u32 = 0,
    cpuidid: [16]u8 = @splat(0),
    cpuidfamily: u8 = 0,
    cpuidmodel: u8 = 0,
    cpuidstepping: u8 = 0,

    havetsc: bool = false,
    havepge: bool = false,
    havewatchpt8: bool = false,
    havenx: bool = false,

    pml4: [*]u64 = undefined, // pml4 base for this processor (va)
    tss: ?*Tss = null, // tss for this processor
    gdt: [*]Segdesc = undefined, // gdt for this processor

    dr7: u64 = 0, // shadow copy of dr7
    xcr0: u64 = 0,

    mmufree: ?*MMU = null, // freelist for MMU structures
    mmucount: u32 = 0, // number of MMU structures in freelist
    mmumap: [4]u64 = @splat(0), // bitmap of pml4 entries for zapping
};

comptime {
    if (@offsetOf(Mach, "splpc") != 8 or @offsetOf(Mach, "proc") != 16)
        @compileError("Mach layout is known to l.zig");
    // The rest of the Mach page is the processor's interrupt and
    // scheduler stack; leave it most of the room.
    if (@sizeOf(Mach) > mem.MACHSIZE / 8) @compileError("Mach too big");
}

/// GS base points at this processor's slot here, so GS:0 is its Mach.
pub export var machp: [mem.MAXMACH]?*Mach = @splat(null);

pub fn MACHP(n: usize) *Mach {
    return machp[n].?;
}

/// This processor.  Not to be held across anything that can switch
/// processes: the process may resume on another one.
pub inline fn m() *Mach {
    return asm volatile ("movq %%gs:0, %[ret]"
        : [ret] "=r" (-> *Mach),
    );
}

/// The process running on this processor, or null in the scheduler and
/// during boot.
pub inline fn up() ?*Proc {
    return m().proc;
}

// FPU states, Proc.fpu.fpstate
pub const FPinit = 0;
pub const FPactive = 1;
pub const FPprotected = 2;
pub const FPinactive = 3; // fpsave valid when fpstate >= FPincative

pub const FPnotify = 0x100; // fp in note handler

/// An XSAVE area: the legacy FXSAVE image, the XSAVE header, and the
/// upper halves of the AVX registers.
pub const FPalloc = struct {
    save: [512 + 64 + 256]u8 align(mem.FPalign) = @splat(0),
    link: ?*FPalloc = null, // when context nests

    /// x87 control word
    pub fn fcw(a: *const FPalloc) u32 {
        return @as(u32, a.save[0]) | @as(u32, a.save[1]) << 8;
    }
    /// x87 status word
    pub fn fsw(a: *const FPalloc) u32 {
        return @as(u32, a.save[2]) | @as(u32, a.save[3]) << 8;
    }
    /// last x87 instruction pointer
    pub fn rip(a: *const FPalloc) usize {
        return @bitCast(a.save[8..16].*);
    }
    pub fn mxcsr(a: *const FPalloc) u32 {
        return @bitCast(a.save[24..28].*);
    }
};

/// Machine-specific FPU state of a process.
/// DIFF: no kfpstate/kfpsave; the kernel does not use the FPU.
pub const PFPU = struct {
    fpstate: i32 = FPinit,
    fpsave: ?*FPalloc = null,
};

/// MMU structure for PDP, PD, PT pages.
pub const MMU = struct {
    next: ?*MMU = null,
    page: [*]u64 = undefined,
    index: usize = 0,
    level: u6 = 0,
};

/// Machine-specific MMU state of a process.
/// DIFF: no kmap list; physical memory is always mapped (DMAP).
pub const PMMU = struct {
    mmuhead: ?*MMU = null,
    mmutail: ?*MMU = null,
    mmucount: u32 = 0,

    dr: [8]u64 = @splat(0),
};

/// Per-page record of which processors must flush their instruction
/// cache before running it.  The x86 keeps its caches coherent itself.
pub const Txtflush = struct {};

pub const Active = struct {
    machs: [mem.MAXMACH]bool = @splat(false), // bitmap of active CPUs
    exiting: bool = false, // shutdown
};

pub var active: Active = .{};

// Trap and interrupt vectors, from 9/pc/io.h.
pub const VectorNMI = 2; // non-maskable interrupt
pub const VectorBPT = 3; // breakpoint
pub const VectorUD = 6; // invalid opcode exception
pub const VectorCNA = 7; // coprocessor not available
pub const Vector2F = 8; // double fault
pub const VectorCSO = 9; // coprocessor segment overrun
pub const VectorSNP = 11; // segment not present
pub const VectorGPF = 13; // general protection fault
pub const VectorPF = 14; // page fault
pub const Vector15 = 15; // reserved
pub const VectorCERR = 16; // coprocessor error
pub const VectorAC = 17; // alignment check
pub const VectorMC = 18; // machine check
pub const VectorSIMD = 19; // simd error

pub const VectorPIC = 32; // external i8259 interrupts
pub const IrqCLOCK = 0;
pub const IrqKBD = 1;
pub const IrqUART1 = 3;
pub const IrqUART0 = 4;
pub const IrqAUX = 12; // PS/2 port
pub const MaxIrqPIC = 15;

pub const VectorLAPIC = VectorPIC + 16; // local APIC interrupts
pub const IrqLINT0 = 16; // LINT[01] must be offsets 0 and 1
pub const IrqLINT1 = 17;
pub const IrqTIMER = 18;
pub const IrqERROR = 19;
pub const IrqPCINT = 20;
pub const IrqSPURIOUS = 31; // must have bits [3-0] == 0x0F
pub const MaxIrqLAPIC = 31;

pub const VectorSYSCALL = 64;

pub const VectorAPIC = 65; // external APIC interrupts
pub const MaxVectorAPIC = 255;

pub const BUSUNKNOWN: i32 = -1;

pub const KNAMELEN = 28;

/// One handler on an interrupt or trap vector.
pub const Vctl = struct {
    next: ?*Vctl = null, // handlers on this vector

    f: *const fn (*Ureg, ?*anyopaque) void, // handler to call
    a: ?*anyopaque = null, // argument to call it with

    isr: ?*const fn (i32) i32 = null, // get isr bit for this irq
    eoi: ?*const fn (i32) i32 = null, // eoi
    enable: ?*const fn (*Vctl, bool) i32 = null, // second argument: vector is shared
    disable: ?*const fn (*Vctl, bool) i32 = null,
    aux: usize = 0, // for the interrupt controller

    name: [KNAMELEN]u8 = @splat(0), // of driver
    isintr: bool = false, // interrupt or fault/trap
    local: bool = false, // local interrupt, not routed through an I/O APIC

    irq: i32 = -1,
    tbdf: i32 = BUSUNKNOWN,
    vno: i32 = -1,
    dest: i32 = -1,
    machno: i32 = -1,
};

// cpuid instruction result register bits
pub const Xsaveopt = 1 << 0; // leaf 0xd.1 ax
pub const Xsaves = 1 << 3;

pub const Monitor = 1 << 3; // leaf 1 cx
pub const X2apic = 1 << 21;
pub const TscDeadline = 1 << 24;
pub const Xsave = 1 << 26;
pub const Avx = 1 << 28;
pub const Rdrnd = 1 << 30;
pub const Hypervisor = 1 << 31;

pub const Fpuonchip = 1 << 0; // leaf 1 dx
pub const Pse = 1 << 3; // page size extensions
pub const Tsc = 1 << 4; // time-stamp counter
pub const Cpumsr = 1 << 5; // model-specific registers, rdmsr/wrmsr
pub const Pae = 1 << 6; // physical-addr extensions
pub const Mce = 1 << 7; // machine-check exception
pub const Cpuapic = 1 << 9;
pub const Mtrr = 1 << 12; // memory-type range regs.
pub const Pge = 1 << 13; // page global extension
pub const Mca = 1 << 14; // machine-check architecture
pub const Pat = 1 << 16; // page attribute table
pub const Clflush = 1 << 19;
pub const Fxsr = 1 << 24; // have SSE FXSAVE/FXRSTOR
pub const Sse = 1 << 25; // thus sfence instr.
pub const Sse2 = 1 << 26; // thus mfence & lfence instr.s

// MSRs
pub const Efer = 0xc0000080; // Extended Feature Enable
pub const Star = 0xc0000081; // Legacy Target IP and [CS]S
pub const Lstar = 0xc0000082; // Long Mode Target IP
pub const Cstar = 0xc0000083; // Compatibility Target IP
pub const Sfmask = 0xc0000084; // SYSCALL Flags Mask
pub const FSbase = 0xc0000100; // 64-bit FS Base Address
pub const GSbase = 0xc0000101; // 64-bit GS Base Address
pub const KernelGSbase = 0xc0000102; // SWAPGS instruction
