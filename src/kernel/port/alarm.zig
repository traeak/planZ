//! Process alarms: the alarm system call's notes.
//! from 9/port/alarm.c

const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const ql = @import("qlock.zig");
const portclock = @import("portclock.zig");

const Proc = portdat.Proc;

var alarms: portdat.Alarms = .{};
var alarmr: portdat.Rendez = .{};

var alarmnote: portdat.Note = blk: {
    var n: portdat.Note = .{ .flag = portdat.NUser, .ref = .{ .ref = 1 } };
    @memcpy(n.msg[0..5], "alarm");
    break :blk n;
};

/// Kernel process that posts the notes of alarms that are due.
pub fn alarmkproc(_: ?*anyopaque) void {
    while (true) {
        const now = arch.MACHP(0).ticks;
        ql.qlock(&alarms.qlock);
        var rp = alarms.head;
        while (rp) |p| : (rp = p.palarm) {
            const when = p.alarm;
            if (when == 0)
                continue;
            if (@as(i32, @bitCast(now -% when)) < 0)
                break;
            if (!ql.canqlock(&p.debug))
                break;
            if (p.alarm != 0) {
                _ = portdat.incref(&alarmnote.ref);
                _ = proc.pushnote(p, &alarmnote);
                p.alarm = 0;
            }
            ql.qunlock(&p.debug);
        }
        alarms.head = rp;
        ql.qunlock(&alarms.qlock);

        // A note to this process is no reason to stop.
        proc.sleep(&alarmr, proc.return0, null) catch {};
    }
}

/// called every clock tick on cpu0
pub fn checkalarms() void {
    const p = alarms.head orelse return;
    const now = arch.MACHP(0).ticks;
    const when = p.alarm;
    if (when == 0 or @as(i32, @bitCast(now -% when)) >= 0)
        _ = proc.wakeup(&alarmr);
}

/// Set the calling process's alarm to `time` milliseconds from now, or
/// cancel it if zero.  Returns what was left of the previous alarm.
pub fn procalarm(time: u32) u32 {
    const up = arch.up().?;
    var when = arch.MACHP(0).ticks;
    var old = up.alarm;
    if (old != 0) {
        old -%= when;
        old = if (@as(i32, @bitCast(old)) > 0) portclock.tk2ms(old) else 0;
    }
    if (time == 0) {
        up.alarm = 0;
        return old;
    }
    when +%= portclock.ms2tk(time);
    if (when == 0)
        when = 1;

    ql.qlock(&alarms.qlock);
    var l: *?*Proc = &alarms.head;
    while (l.*) |f| : (l = &f.palarm) {
        if (up == f) {
            l.* = f.palarm;
            break;
        }
    }
    l = &alarms.head;
    while (l.*) |f| : (l = &f.palarm) {
        const t = f.alarm;
        if (t != 0 and @as(i32, @bitCast(t -% when)) >= 0)
            break;
    }
    up.palarm = l.*;
    l.* = up;
    up.alarm = when;
    ql.qunlock(&alarms.qlock);
    return old;
}
