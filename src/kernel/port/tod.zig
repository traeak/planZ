//! Time of day.
//! from 9/port/tod.c
//!
//! Compute nanosecond epoch time from the fastest ticking clock on the
//! system.  Converting the time to nanoseconds requires the following
//! formula
//!
//!    t = (((1000000000<<31)/f)*ticks)>>31
//!
//! where
//!
//!    'f'  is the clock frequency
//!    'ticks'  are clock ticks
//!
//! to avoid too much calculation in todget(), we calculate
//!
//!    mult = (1000000000<<32)/f
//!
//! each time f is set.  f is normally set by a user level program
//! writing to /dev/fastclock.  mul64fract will then take that fractional
//! multiplier and a 64 bit integer and return the resulting integer
//! product.
//!
//! We assume that the cpu's of a multiprocessor are synchronized.  This
//! assumption needs to be questioned with each new architecture.

const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const portclock = @import("portclock.zig");
const p9 = @import("print.zig");

const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const HZ = arch.mem.HZ;

// frequency of the tod clock
const TODFREQ = 1000000000;
const MicroFREQ = 1000000;

var tod: struct {
    lock: taslock.Lock = .{},
    multiplier: u64 = 0, // ns = off + (multiplier*ticks)>>31
    divider: u64 = 0, // ticks = (divider*(ns-off))>>31
    umultiplier: u64 = 0, // µs = (µmultiplier*ticks)>>31
    udivider: u64 = 0, // ticks = (µdivider*µs)>>31
    hz: u64 = 0, // frequency of fast clock
    last: u64 = 0, // last reading of fast clock
    bootoff: u64 = 0, // offset from boot to last (ns)
    lastuptime: u64 = 0, // last uptime returned from todget()
    off: u64 = 0, // offset from epoch to last (ns)
    lasttime: u64 = 0, // last nsecs returned from todget()
    delta: i64 = 0, // add 'delta' each slow clock tick from sstart to send
    sstart: u32 = 0, // ...
    send: u32 = 0, // ...
    init: bool = false, // true if initialized
} = .{};

/// a * b, where b is a 32.32 fixed point fraction.
/// from mul64fract in 9/pc64/l.s
fn mul64fract(a: u64, b: u64) u64 {
    return @truncate((@as(u128, a) * b) >> 32);
}

pub fn todinit() void {
    ilock(&tod.lock);
    if (tod.init) {
        iunlock(&tod.lock);
        return;
    }
    tod.init = true;
    tod.last = arch.fastticks(&tod.hz);
    iunlock(&tod.lock);
    todsetfreq(tod.hz);
    _ = portclock.addclock0link(todfix, 2000);
}

fn deltans(ticks_: u64) u64 {
    const ticks = ticks_ -% tod.last;
    if (@as(i64, @bitCast(ticks)) <= 0)
        return 0;
    return mul64fract(ticks, tod.multiplier);
}

/// calculate multiplier
pub fn todsetfreq(f: u64) void {
    if (f == 0)
        p9.panic("todsetfreq: freq %lld <= 0", .{f});
    ilock(&tod.lock);
    tod.hz = f;

    // calculate multiplier for time conversion
    tod.multiplier = mk64fract(TODFREQ, f);
    tod.divider = mk64fract(f, TODFREQ) + 1;
    tod.umultiplier = mk64fract(MicroFREQ, f);
    tod.udivider = mk64fract(f, MicroFREQ) + 1;
    iunlock(&tod.lock);
}

/// Set the time of day struct
pub fn todset(t: i64, delta_: i64, n_: i32) void {
    var delta = delta_;
    var n: i64 = n_;
    if (!tod.init)
        todinit();

    ilock(&tod.lock);
    if (t >= 0) {
        const ticks = arch.fastticks(null);
        tod.bootoff +%= deltans(ticks);
        tod.off = @intCast(t);
        tod.last = ticks;
        tod.lasttime = 0;
        tod.delta = 0;
        tod.sstart = tod.send;
    } else {
        if (n <= 0)
            n = 1;
        n *= HZ;
        if (delta < 0 and n > -delta)
            n = -delta;
        if (delta > 0 and n > delta)
            n = delta;
        if (n == 0) {
            p9.iprint("todset: n == 0, delta == %lld\n", .{delta});
            delta = 0;
        } else delta = @divTrunc(delta, n);
        tod.sstart = arch.MACHP(0).ticks;
        tod.send = tod.sstart +% @as(u32, @intCast(n));
        tod.delta = delta;
    }
    iunlock(&tod.lock);
}

pub const Tod = struct {
    /// Nanoseconds since the epoch.
    nsec: i64,
    /// Fast clock reading and its rate.
    ticks: u64,
    hz: u64,
    /// Nanoseconds since boot; never goes backwards.
    uptime: i64,
};

/// get time of day
/// DIFF: returns everything at once; the C takes four optional
/// pointers.
pub fn todget() Tod {
    if (!tod.init)
        todinit();

    // we don't want time to pass twixt the measuring of fastticks
    // and grabbing tod.last.  Also none of the vlongs are atomic so
    // we have to look at them inside the lock.
    ilock(&tod.lock);
    defer iunlock(&tod.lock);
    const ticks = arch.fastticks(null);
    var ns = deltans(ticks);

    // uptime is monotonic time from boot
    var up = ns +% tod.bootoff;
    // uptime can't go backwards
    if (up < tod.lastuptime)
        up = tod.lastuptime
    else
        tod.lastuptime = up;

    // add in correction
    if (tod.sstart != tod.send) {
        var t = arch.MACHP(0).ticks;
        if (t >= tod.send)
            t = tod.send;
        tod.off = @bitCast(@as(i64, @bitCast(tod.off)) +% tod.delta *% (t -% tod.sstart));
        tod.sstart = t;
    }

    // convert to epoch
    ns +%= tod.off;

    // time can't go backwards (except when /dev/[bin]time is written)
    if (ns < tod.lasttime)
        ns = tod.lasttime
    else
        tod.lasttime = ns;

    return .{ .nsec = @bitCast(ns), .ticks = ticks, .hz = tod.hz, .uptime = @bitCast(up) };
}

/// called regularly to avoid calculation overflows
fn todfix() void {
    ilock(&tod.lock);
    const ticks = arch.fastticks(null);
    if (@as(i64, @bitCast(ticks -% tod.last)) > tod.hz) {
        const ns = deltans(ticks);
        tod.last = ticks;
        tod.bootoff +%= ns;
        tod.off +%= ns;
    }
    iunlock(&tod.lock);
}

pub fn nsec() i64 {
    return todget().nsec;
}

pub fn uptime() i64 {
    return todget().uptime;
}

pub fn seconds() i64 {
    return @divTrunc(nsec(), TODFREQ);
}

pub fn fastticks2us(ticks: u64) u64 {
    if (!tod.init) todinit();
    return mul64fract(ticks, tod.umultiplier);
}

pub fn us2fastticks(us: u64) u64 {
    if (!tod.init) todinit();
    return mul64fract(us, tod.udivider);
}

/// convert milliseconds to fast ticks
pub fn ms2fastticks(ms: u32) u64 {
    if (!tod.init) todinit();
    return (tod.hz * ms) / 1000;
}

/// convert nanoseconds to fast ticks
pub fn ns2fastticks(ns: u64) u64 {
    if (!tod.init) todinit();
    return mul64fract(ns, tod.divider);
}

/// convert fast ticks to ns
pub fn fastticks2ns(ticks: u64) u64 {
    if (!tod.init) todinit();
    return mul64fract(ticks, tod.multiplier);
}

/// Make a 64 bit fixed point number that has a decimal point
/// to the left of the low order 32 bits.  This is used with
/// mul64fract for converting twixt nanoseconds and fastticks.
///
///    multiplier = (to<<32)/from
fn mk64fract(to_: u64, from: u64) u64 {
    var to = to_;
    if (to == 0) return 0;

    var shift: u6 = 0;
    while (shift < 32 and to < (1 << (32 + 24))) {
        to <<= 8;
        shift += 8;
    }
    while (shift < 32 and to < (1 << (32 + 31))) {
        to <<= 1;
        shift += 1;
    }

    return (to / from) << (32 - shift);
}
