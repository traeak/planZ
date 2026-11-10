//! Interrupt and trap handler registration and dispatch.
//! from 9/pc/irq.c
//!
//! DIFF: the PCArch indirection is gone (there is one interrupt
//! architecture, the APIC); the service-time histogram, preemption on
//! the clock interrupt and the irqalloc file are not here yet.

const std = @import("std");
const dat = @import("dat.zig");
const l = @import("l.zig");
const apic = @import("apic.zig");
const taslock = @import("../../port/taslock.zig");
const xalloc = @import("../../port/xalloc.zig");
const p9 = @import("../../port/print.zig");
const print = p9.print;
const iprint = p9.iprint;
const panic = p9.panic;

const Ureg = dat.Ureg;
const Vctl = dat.Vctl;
const m = dat.m;

pub const Handler = *const fn (*Ureg, ?*anyopaque) void;

var vctllock: taslock.Lock = .{};
var vclock: ?*Vctl = null;
var vctl: [256]?*Vctl = @splat(null);

/// Run the handlers for vector `vno`.  Returns 1 if it was handled, 0 if
/// it is a trap nobody claimed, -1 for a spurious interrupt.
pub fn irqhandled(ureg: *Ureg, vno: usize) i32 {
    const mach = m();
    if (vctl[vno]) |ctl| {
        if (vno < dat.VectorPIC) {
            ctl.f(ureg, ctl.a);
            return 1;
        }

        mach.intr +%= 1;
        mach.lastintr = ctl.irq;
        if (ctl.isr) |isr| _ = isr(@intCast(vno));
        var v: ?*Vctl = ctl;
        while (v) |h| : (v = h.next) h.f(ureg, h.a);
        if (ctl.eoi) |eoi| _ = eoi(@intCast(vno));
        return 1;
    }

    if (vno < dat.VectorPIC or vno == dat.VectorSYSCALL)
        return 0;

    mach.spuriousintr +%= 1;
    if (apic.intrspurious(vno))
        return 1; // false alarm

    iprint("cpu%d: spurious interrupt %d, last %d\n", .{ mach.machno, vno, mach.lastintr });

    // call all non-local interrupt routines, just in case
    for (vctl[dat.VectorPIC..]) |c| {
        const ctl = c orelse continue;
        if (ctl == vclock or ctl.local) continue;
        var v: ?*Vctl = ctl;
        while (v) |h| : (v = h.next) h.f(ureg, h.a);
    }
    return -1;
}

fn newvctl(f: Handler, a: ?*anyopaque, name: []const u8) *Vctl {
    const p = xalloc.xalloc(@sizeOf(Vctl)) orelse panic("intrenable: out of memory", .{});
    const v: *Vctl = @ptrFromInt(p);
    v.* = .{ .f = f, .a = a };
    const n = @min(name.len, v.name.len - 1);
    @memcpy(v.name[0..n], name[0..n]);
    return v;
}

fn nameof(v: *const Vctl) []const u8 {
    return std.mem.sliceTo(&v.name, 0);
}

/// Install the handler for a processor exception.
pub fn trapenable(vno: usize, f: Handler, a: ?*anyopaque, name: []const u8) void {
    if (vno >= dat.VectorPIC) {
        print("trapenable: vno %d out of range", .{vno});
        return;
    }
    const v = newvctl(f, a, name);
    v.vno = @intCast(vno);

    taslock.ilock(&vctllock);
    if (vctl[vno]) |old| {
        print("trapenable: vno %d assigned twice: %s %s\n", .{ vno, nameof(old), nameof(v) });
        taslock.iunlock(&vctllock);
        xalloc.xfree(@intFromPtr(v));
        return;
    }
    vctl[vno] = v;
    taslock.iunlock(&vctllock);
}

/// Install a handler for interrupt `irq` of the device at `tbdf`.
pub fn intrenable(irq: i32, f: Handler, a: ?*anyopaque, tbdf: i32, name: []const u8) void {
    const v = newvctl(f, a, name);
    v.isintr = true;
    v.tbdf = tbdf;
    v.irq = irq;

    taslock.ilock(&vctllock);
    v.vno = apic.intrassign(v);
    if (v.vno < dat.VectorPIC or v.vno >= vctl.len) {
        print("intrenable: couldn't assign irq %d, tbdf %#ux for %s\n", .{ irq, tbdf, nameof(v) });
        taslock.iunlock(&vctllock);
        xalloc.xfree(@intFromPtr(v));
        return;
    }
    const vno: usize = @intCast(v.vno);
    var pv: *?*Vctl = &vctl[vno];
    if (pv.*) |old| {
        if (old.isr != v.isr or old.eoi != v.eoi) {
            print("intrenable: incompatible handler: %s %s\n", .{ nameof(old), nameof(v) });
            taslock.iunlock(&vctllock);
            xalloc.xfree(@intFromPtr(v));
            return;
        }
        // The clock handler stays first on its vector.
        if (old == vclock) pv = &old.next;
        v.next = pv.*;
    }
    if (std.mem.eql(u8, name, "clock"))
        vclock = v;
    pv.* = v;
    if (v.enable) |enable| {
        l.coherence();
        if (enable(v, pv != &vctl[vno] or v.next != null) < 0) {
            print("intrenable: couldn't enable irq %d, tbdf %#ux for %s\n", .{ irq, tbdf, nameof(v) });
            pv.* = v.next;
            if (v == vclock) vclock = null;
            taslock.iunlock(&vctllock);
            // DIFF: with more than one processor the C delays this free,
            // since another one may be running the handler list.
            xalloc.xfree(@intFromPtr(v));
            return;
        }
    }
    taslock.iunlock(&vctllock);
}
