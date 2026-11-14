//! What a console's `mouse` and `kbd` files hold for a program that
//! draws on the console (rio, say), as rio keeps them for a window
//! (wind.c, winctl: WMouse, WMouseread, WKbd, WKbdread).
//!
//! The mouse: the latest state, and a ring of the states at which a
//! button changed, so that a click is not lost between two reads.  A
//! read gets the oldest queued click, or the latest state if it has
//! not been read yet.  A ring that fills is dropped whole (rio:
//! frantic clicking during a long wait).
//!
//! The keyboard: kbdfs's messages (k, K, c and their runes, see
//! keys.zig), queued whole, each with its NUL.  When the console stops
//! being the current one its program is sent a bare K, all keys up:
//! it saw Ctl and Alt go down for the switch and will not see them
//! released.
//!
//! Not part of 9front: vtfs.

const std = @import("std");

pub const Mouse = struct {
    x: i32 = 0,
    y: i32 = 0,
    buttons: i32 = 0,
    msec: u32 = 0,
};

/// A line of /dev/mouse: m or r, then x, y, buttons and msec.
pub fn parse(s: []const u8) ?Mouse {
    if (s.len < 2 or (s[0] != 'm' and s[0] != 'r'))
        return null;
    var it = std.mem.tokenizeAny(u8, s[1..], " \t\n\x00");
    var v: [4]i64 = @splat(0);
    for (&v, 0..) |*p, i| {
        const f = it.next() orelse {
            if (i < 3) return null;
            break;
        };
        p.* = std.fmt.parseInt(i64, f, 10) catch return null;
    }
    return .{
        .x = @truncate(v[0]),
        .y = @truncate(v[1]),
        .buttons = @truncate(v[2]),
        .msec = @truncate(@as(u64, @bitCast(v[3]))),
    };
}

pub const MouseQ = struct {
    const State = struct { m: Mouse, counter: u32 };

    m: Mouse = .{},
    counter: u32 = 0,
    lastcounter: u32 = 0,
    lastb: i32 = 0,
    queue: [16]State = undefined,
    ri: usize = 0,
    wi: usize = 0,
    qfull: bool = false,

    /// The mouse moved or a button changed.
    pub fn put(q: *MouseQ, m: Mouse) void {
        q.m = m;
        q.counter +%= 1;
        if (!q.qfull and q.lastb != m.buttons) {
            q.queue[q.wi] = .{ .m = m, .counter = q.counter };
            q.wi = (q.wi + 1) % q.queue.len;
            if (q.wi == q.ri)
                q.qfull = true;
            q.lastb = m.buttons;
        }
    }

    /// The console is no longer current: its buttons are up.
    pub fn release(q: *MouseQ) void {
        if (q.m.buttons != 0) {
            var m = q.m;
            m.buttons = 0;
            q.put(m);
        }
    }

    /// Is there something a read has not seen?
    pub fn ready(q: *const MouseQ) bool {
        return q.counter != q.lastcounter;
    }

    pub fn get(q: *MouseQ) Mouse {
        var s: State = .{ .m = q.m, .counter = q.counter };
        if (q.qfull) {
            q.qfull = false;
            q.ri = q.wi;
        } else if (q.wi != q.ri) {
            s = q.queue[q.ri];
            q.ri = (q.ri + 1) % q.queue.len;
        }
        q.lastcounter = s.counter;
        return s.m;
    }
};

pub const KbdQ = struct {
    const Max = 32; // messages, as rio's ring

    buf: [Max * 64]u8 = undefined,
    len: usize = 0,
    n: usize = 0,
    keyup: bool = false,

    /// Queue one message (without its NUL).  A message that does not
    /// fit is dropped, as rio drops one when its ring is full.
    pub fn put(q: *KbdQ, m: []const u8) void {
        if (q.n >= Max or q.len + m.len + 1 > q.buf.len)
            return;
        @memcpy(q.buf[q.len..][0..m.len], m);
        q.buf[q.len + m.len] = 0;
        q.len += m.len + 1;
        q.n += 1;
    }

    /// The console is no longer current: its keys are up.
    pub fn release(q: *KbdQ) void {
        q.keyup = true;
    }

    pub fn ready(q: *const KbdQ) bool {
        return q.n > 0 or q.keyup;
    }

    /// As many whole messages as fit in out, then the K.
    pub fn get(q: *KbdQ, out: []u8) usize {
        var nb: usize = 0;
        var p: usize = 0;
        while (q.n > 0) {
            const e = std.mem.indexOfScalarPos(u8, q.buf[0..q.len], p, 0).? + 1;
            if (nb + (e - p) > out.len)
                break;
            @memcpy(out[nb..][0 .. e - p], q.buf[p..e]);
            nb += e - p;
            p = e;
            q.n -= 1;
        }
        std.mem.copyForwards(u8, q.buf[0 .. q.len - p], q.buf[p..q.len]);
        q.len -= p;
        if (q.keyup and nb + 2 <= out.len) {
            q.keyup = false;
            out[nb] = 'K';
            out[nb + 1] = 0;
            nb += 2;
        }
        return nb;
    }

    pub fn reset(q: *KbdQ) void {
        q.len = 0;
        q.n = 0;
        q.keyup = false;
    }
};

test "a line of /dev/mouse" {
    const m = parse("m        100         200           1       12345 ").?;
    try std.testing.expectEqual(Mouse{ .x = 100, .y = 200, .buttons = 1, .msec = 12345 }, m);
    try std.testing.expectEqual(@as(i32, -5), parse("r -5 7 0 1").?.x);
    try std.testing.expectEqual(null, parse("x 1 2 3 4"));
    try std.testing.expectEqual(null, parse("m 1 2"));
    try std.testing.expectEqual(null, parse(""));
}

test "motion: only the latest state, once" {
    var q: MouseQ = .{};
    try std.testing.expect(!q.ready());
    q.put(.{ .x = 1 });
    q.put(.{ .x = 2 });
    q.put(.{ .x = 3 });
    try std.testing.expect(q.ready());
    try std.testing.expectEqual(@as(i32, 3), q.get().x);
    try std.testing.expect(!q.ready());
}

test "clicks are kept in order, each with its position" {
    var q: MouseQ = .{};
    q.put(.{ .x = 1, .buttons = 1 });
    q.put(.{ .x = 2, .buttons = 0 });
    q.put(.{ .x = 3, .buttons = 4 });
    q.put(.{ .x = 9, .buttons = 4 }); // motion with the button held
    try std.testing.expectEqual(Mouse{ .x = 1, .buttons = 1 }, q.get());
    try std.testing.expect(q.ready());
    try std.testing.expectEqual(Mouse{ .x = 2, .buttons = 0 }, q.get());
    try std.testing.expectEqual(Mouse{ .x = 3, .buttons = 4 }, q.get());
    try std.testing.expect(q.ready()); // the motion
    try std.testing.expectEqual(Mouse{ .x = 9, .buttons = 4 }, q.get());
    try std.testing.expect(!q.ready());
}

test "a full ring is dropped; the latest state is read" {
    var q: MouseQ = .{};
    for (0..40) |i|
        q.put(.{ .x = @intCast(i), .buttons = @intCast(i & 1) });
    const m = q.get();
    try std.testing.expectEqual(@as(i32, 39), m.x);
    try std.testing.expect(!q.ready());
    // and it works again
    q.put(.{ .x = 50, .buttons = 0 });
    try std.testing.expectEqual(@as(i32, 50), q.get().x);
}

test "release: a held button goes up, once" {
    var q: MouseQ = .{};
    q.put(.{ .x = 4, .y = 5, .buttons = 2 });
    _ = q.get();
    q.release();
    try std.testing.expect(q.ready());
    try std.testing.expectEqual(Mouse{ .x = 4, .y = 5, .buttons = 0 }, q.get());
    q.release();
    try std.testing.expect(!q.ready());
}

test "kbd messages come whole, each with its NUL" {
    var q: KbdQ = .{};
    try std.testing.expect(!q.ready());
    q.put("k\xef\x80\x97");
    q.put("ca");
    q.put("K");
    var b: [64]u8 = undefined;
    // room for the first only
    try std.testing.expectEqualStrings("k\xef\x80\x97\x00", b[0..q.get(b[0..6])]);
    try std.testing.expect(q.ready());
    try std.testing.expectEqualStrings("ca\x00K\x00", b[0..q.get(&b)]);
    try std.testing.expect(!q.ready());
    try std.testing.expectEqual(@as(usize, 0), q.get(&b));
}

test "kbd release: a bare K after what is queued" {
    var q: KbdQ = .{};
    q.put("k\x01");
    q.release();
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("k\x01\x00K\x00", b[0..q.get(&b)]);
    try std.testing.expect(!q.ready());
    q.release();
    try std.testing.expect(q.ready());
    try std.testing.expectEqualStrings("K\x00", b[0..q.get(&b)]);
}

test "kbd: no more than the ring holds" {
    var q: KbdQ = .{};
    for (0..100) |_| q.put("cx");
    var b: [1024]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32 * 3), q.get(&b));
    q.put("cy");
    try std.testing.expectEqualStrings("cy\x00", b[0..q.get(&b)]);
}
