//! What vtfs makes of the keyboard: the messages of kbdfs's /dev/kbd
//! (kbdfs(8)), each a type and runes:
//!   k    the keys now held, after one went down
//!   K    the keys now held, after one went up
//!   c    a character typed
//! The keys held give Ctl, Alt and Shift, and the key that went down
//! last.  A character typed with Ctl and Alt held while the last key
//! down is Left or Right steps to the previous or next console;
//! 1 to 9 or 0 goes to that console if there is one.  The character
//! (Left, Right, or what Ctl makes of the digit) is then not typed.
//! Characters from the serial line come without k and K.
//!
//! Not part of 9front: vtfs.

const std = @import("std");
const libc = @import("libc");
const text = @import("text.zig");

const Rune = libc.Rune;

pub const Event = union(enum) {
    none,
    key: struct { r: Rune, shift: bool }, // for the current console
    prev,
    next,
    go: usize, // to this console, from 0
};

pub const Keys = struct {
    down: [32]Rune = undefined,
    ndown: usize = 0,
    nconsole: usize,

    fn held(k: *const Keys, r: Rune) bool {
        return std.mem.indexOfScalar(Rune, k.down[0..k.ndown], r) != null;
    }

    /// One message, without its NUL.
    pub fn msg(k: *Keys, m: []const u8) Event {
        if (m.len == 0)
            return .none;
        switch (m[0]) {
            'k', 'K' => {
                k.ndown = 0;
                var s = m[1..];
                while (s.len > 0 and k.ndown < k.down.len) {
                    const c = libc.chartorune(s);
                    k.down[k.ndown] = c.r;
                    k.ndown += 1;
                    s = s[c.n..];
                }
                return .none;
            },
            'c' => {
                if (m.len < 2)
                    return .none;
                const r = libc.chartorune(m[1..]).r;
                if (k.ndown > 0 and k.held(text.Kctl) and k.held(text.Kalt)) {
                    const last = k.down[k.ndown - 1];
                    switch (last) {
                        text.Kleft => return .prev,
                        text.Kright => return .next,
                        '0'...'9' => {
                            const n: usize = if (last == '0') 9 else last - '1';
                            return if (n < k.nconsole) .{ .go = n } else .none;
                        },
                        else => {},
                    }
                }
                return .{ .key = .{ .r = r, .shift = k.held(text.Kshift) } };
            },
            else => return .none,
        }
    }
};

/// The messages in what one read of /dev/kbd gave: each ends in a NUL.
pub fn split(data: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\x00"), 0);
}

inline fn utf(comptime rs: []const Rune) []const u8 {
    comptime {
        var b: [rs.len * 4]u8 = undefined;
        var n: usize = 0;
        for (rs) |r| n += std.unicode.utf8Encode(r, b[n..]) catch unreachable;
        const out = b[0..n].*;
        return &out;
    }
}

test "Ctl-Alt with an arrow or a digit switches; the character is not typed" {
    var k: Keys = .{ .nconsole = 4 };
    const evs = [_]struct { m: []const u8, e: Event }{
        .{ .m = "k" ++ utf(&.{text.Kctl}), .e = .none },
        .{ .m = "k" ++ utf(&.{ text.Kctl, text.Kalt }), .e = .none },
        .{ .m = "k" ++ utf(&.{ text.Kctl, text.Kalt, text.Kright }), .e = .none },
        .{ .m = "c" ++ utf(&.{text.Kright}), .e = .next },
        .{ .m = "c" ++ utf(&.{text.Kright}), .e = .next }, // repeat
        .{ .m = "K" ++ utf(&.{ text.Kctl, text.Kalt }), .e = .none },
        .{ .m = "k" ++ utf(&.{ text.Kctl, text.Kalt, text.Kleft }), .e = .none },
        .{ .m = "c" ++ utf(&.{text.Kleft}), .e = .prev },
        .{ .m = "K" ++ utf(&.{ text.Kctl, text.Kalt }), .e = .none },
        .{ .m = "k" ++ utf(&.{ text.Kctl, text.Kalt, '3' }), .e = .none },
        .{ .m = "c\x13", .e = .{ .go = 2 } },
        .{ .m = "K" ++ utf(&.{ text.Kctl, text.Kalt }), .e = .none },
        .{ .m = "k" ++ utf(&.{ text.Kctl, text.Kalt, '7' }), .e = .none },
        .{ .m = "c\x17", .e = .none }, // no console 7: nothing
        .{ .m = "K", .e = .none },
    };
    for (evs) |x|
        try std.testing.expectEqualDeep(x.e, k.msg(x.m));
}

test "other keys are typed, with Shift; serial input has no k" {
    var k: Keys = .{ .nconsole = 4 };
    try std.testing.expectEqualDeep(Event{ .key = .{ .r = 'a', .shift = false } }, k.msg("ca"));
    _ = k.msg("k" ++ utf(&.{ text.Kshift, text.Kpgup }));
    try std.testing.expectEqualDeep(Event{ .key = .{ .r = text.Kpgup, .shift = true } }, k.msg("c" ++ utf(&.{text.Kpgup})));
    _ = k.msg("K");
    // Ctl alone: the control character is typed
    _ = k.msg("k" ++ utf(&.{ text.Kctl, 'u' }));
    try std.testing.expectEqualDeep(Event{ .key = .{ .r = 0x15, .shift = false } }, k.msg("c\x15"));
    _ = k.msg("K");
    try std.testing.expectEqualDeep(Event{ .key = .{ .r = 0x263A, .shift = false } }, k.msg("c\xe2\x98\xba"));
}

test "a read holds several messages" {
    var it = split("k\xef\x80\x97\x00ca\x00K\x00");
    try std.testing.expectEqualStrings("k\xef\x80\x97", it.next().?);
    try std.testing.expectEqualStrings("ca", it.next().?);
    try std.testing.expectEqualStrings("K", it.next().?);
    try std.testing.expectEqual(null, it.next());
}
