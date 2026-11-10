//! What the amd64 port provides to the portable kernel; see ../../arch.zig.

pub const mem = @import("mem.zig");
pub const dat = @import("dat.zig");
const l = @import("l.zig");
const mmu = @import("mmu.zig");
const memory = @import("memory.zig");
const trapmod = @import("trap.zig");
const mainmod = @import("main.zig");

pub const Mach = dat.Mach;
pub const Conf = dat.Conf;
pub const Confmem = dat.Confmem;
pub const Label = dat.Label;
pub const Ureg = dat.Ureg;

pub const m = dat.m;
pub const up = dat.up;
pub const MACHP = dat.MACHP;

pub const splhi = l.splhi;
pub const spllo = l.spllo;
pub const splx = l.splx;
pub const islo = l.islo;
pub const tas = l.tas;
pub const coherence = l.coherence;

pub const kaddr = mmu.kaddr;
pub const paddr = mmu.paddr;
pub const rampage = memory.rampage;
pub const dumpstack = trapmod.dumpstack;

pub const _start = l._start;
pub const main = mainmod.main;
pub const trap = trapmod.trap;
