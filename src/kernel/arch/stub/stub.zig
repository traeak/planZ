//! An architecture that does nothing, with the interface arch.zig
//! expects.  `zig build check-ports` compiles the portable kernel
//! against it for aarch64 and riscv64, so that x86 assumptions in
//! port/ show up as compile errors long before either port exists.
//! Nothing here is ever run.

const portdat = @import("../../port/portdat.zig");

pub const mem = struct {
    pub const KiB = 1024;
    pub const MiB = 1024 * KiB;
    pub const GiB = 1024 * MiB;
    pub const BY2PG = 0x1000;
    pub const BY2V = 8;
    pub const PGSHIFT = 12;
    pub const MAXMACH = 128;
    pub const KSTACK = 16 * KiB;
    pub const MACHSIZE = 2 * KSTACK;
    pub const HZ = 100;
    pub const BY2WD = 8;
    pub const UTZERO: usize = 0x200000;
    pub const USTKTOP: usize = 0x00007ffffffff000;
    pub const USTKSIZE = 16 * MiB;
    pub const KZERO: usize = 0xffffffff80000000;
    pub const FPalign = 64;
    pub const PTEMAPMEM = 1 * MiB;
    pub const PTEPERTAB = PTEMAPMEM / BY2PG;
    pub const SEGMAPSIZE = 65536;
    pub const SSEGMAPSIZE = 16;
    pub const PTEVALID: u64 = 1 << 0;
    pub const PTEWRITE: u64 = 1 << 1;
    pub const PTERONLY: u64 = 0 << 1;
    pub const PTEUSER: u64 = 1 << 2;
    pub const PTEUNCACHED: u64 = 1 << 4;
    pub const PTECACHED: u64 = 0 << 4;

    pub fn PGROUND(s: usize) usize {
        return (s + BY2PG - 1) & ~@as(usize, BY2PG - 1);
    }
};

pub const Proc = portdat.Proc;

pub const Label = extern struct { sp: usize = 0, pc: usize = 0 };

pub const Ureg = extern struct { pc: u64 = 0, sp: u64 = 0 };

pub const Confmem = extern struct {
    base: usize = 0,
    npage: usize = 0,
    kbase: usize = 0,
    klimit: usize = 0,
};

pub const Conf = struct {
    nmach: u32 = 0,
    nproc: u32 = 0,
    npage: usize = 0,
    upages: usize = 0,
    mem: [64]Confmem = @splat(.{}),
};

pub const Perf = extern struct {
    intrts: u32 = 0,
    inintr: u32 = 0,
    avg_inintr: u32 = 0,
    inidle: u32 = 0,
    avg_inidle: u32 = 0,
    last: u32 = 0,
    period: u32 = 0,
};

pub const Mach = struct {
    machno: i32 = 0,
    proc: ?*Proc = null,
    readied: ?*Proc = null,
    sched: Label = .{},
    ticks: u32 = 0,
    schedticks: u32 = 0,
    cs: i32 = 0,
    load: i32 = 0,
    ilockdepth: i32 = 0,
    tlbflush: u32 = 0,
    pfault: u32 = 0,
    syscall: i32 = 0,
    perf: Perf = .{},
};

pub const PFPU = struct {};
pub const PMMU = struct {};
/// A real aarch64 or riscv64 port keeps a per-processor bitmap here.
pub const Txtflush = struct {};
pub fn inittxtflush(_: *portdat.Page) void {}
pub fn settxtflush(_: *portdat.Page, _: bool) void {}
pub const AOUT_MAGIC: u32 = 0;

pub fn putmmu(_: usize, _: u64, _: *portdat.Page) void {}
pub fn flushmmu() void {}
pub fn checkmmu(_: usize, _: u64) void {}
pub fn kmap(page: *portdat.Page) usize {
    return page.pa;
}
pub fn kunmap(_: usize) void {}
pub fn vmap(_: u64, _: usize) ?usize {
    return null;
}
pub fn vunmap(_: usize, _: usize) void {}
pub fn upaalloc(_: u64, _: u64, _: u64) u64 {
    return ~@as(u64, 0);
}
pub fn upafree(_: u64, _: u64) void {}
pub const BUSUNKNOWN: i32 = -1;
pub fn intrenable(_: i32, _: *const fn (*Ureg, ?*anyopaque) void, _: ?*anyopaque, _: i32, _: []const u8) void {}
pub fn intrdisable(_: i32, _: *const fn (*Ureg, ?*anyopaque) void, _: ?*anyopaque, _: i32, _: []const u8) void {}
pub fn probe(_: usize, _: bool) callconv(.c) bool {
    return true;
}
pub fn PTENOEXEC() u64 {
    return 0;
}
pub fn procsetup(_: *Proc) void {}
pub fn procfork(_: *Proc) void {}
pub fn forkchild(_: *Proc, _: *Ureg) void {}
pub fn execregs(_: usize, _: usize, _: usize, _: usize) usize {
    return 0;
}
pub fn userpc() usize {
    return 0;
}
pub fn setregisters(_: *Ureg, _: *const Ureg) void {}
pub fn setkernur(_: *Ureg, _: *Proc) void {}
pub fn validalign(_: usize) bool {
    return true;
}
pub fn touser(_: usize) callconv(.c) noreturn {
    while (true) {}
}
pub fn notify(_: *Ureg, _: []const u8) ?*Ureg {
    return null;
}
pub fn noted(_: *Ureg, _: *Ureg, _: i32) bool {
    return false;
}
pub fn fpunotify(_: *Proc) void {}
pub fn fpunoted(_: *Proc) void {}
pub fn syscall(_: *Ureg) callconv(.c) usize {
    return 0;
}

pub const Active = struct {
    machs: [mem.MAXMACH]bool = @splat(false),
    exiting: bool = false,
};

pub const dat = struct {
    pub var conf: Conf = .{};
    pub var active: Active = .{};
    pub var mach0: Mach = .{};
};

pub const active = &dat.active;

pub fn m() *Mach {
    return &dat.mach0;
}
pub fn up() ?*Proc {
    return m().proc;
}
pub fn setup(p: ?*Proc) void {
    m().proc = p;
}
pub fn MACHP(_: usize) *Mach {
    return &dat.mach0;
}

pub fn splhi() usize {
    return 0;
}
pub fn spllo() usize {
    return 0;
}
pub fn splx(_: usize) void {}
pub fn islo() bool {
    return false;
}
pub fn tas(key: *u32) u32 {
    return @atomicRmw(u32, key, .Xchg, 0xdeaddead, .seq_cst);
}
pub fn coherence() void {}
pub fn stop() noreturn {
    while (true) {}
}

pub fn kaddr(pa: u64) usize {
    return pa;
}
pub fn paddr(va: usize) u64 {
    return va;
}
pub fn rampage() usize {
    return 0;
}
pub fn dumpstack() void {}

pub fn swtch(_: *Label, _: *Label) callconv(.c) void {}
pub fn kprocchild(_: *Proc, _: *const fn () callconv(.c) noreturn) void {}
pub fn procnew(_: *Proc) void {}
pub fn procsave(_: *Proc) void {}
pub fn procrestore(_: *Proc) void {}
pub fn mmuswitch(_: *Proc, _: bool) void {}
pub fn mmurelease(_: *Proc) void {}
pub fn userureg(_: *const Ureg) bool {
    return false;
}
pub fn dbgpc(_: *Proc) usize {
    return 0;
}
pub fn idlehands(_: *const i32) void {}

pub fn cycles() u64 {
    return 0;
}
pub fn perfticks() u32 {
    return 0;
}
pub fn fastticks(hz: ?*u64) u64 {
    if (hz) |h| h.* = 1;
    return 0;
}
pub fn timerset(_: u64) void {}
pub fn delay(_: u64) void {}
pub fn microdelay(_: u64) void {}
pub fn getconf(_: []const u8) ?[]const u8 {
    return null;
}

pub fn _start() callconv(.c) noreturn {
    while (true) {}
}
pub fn main(_: u64) callconv(.c) noreturn {
    while (true) {}
}
pub fn trap(_: *Ureg) callconv(.c) void {}
