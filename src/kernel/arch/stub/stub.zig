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
    perf: Perf = .{},
};

pub const PFPU = struct {};
pub const PMMU = struct {};

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
