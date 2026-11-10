//! The parts of libc the kernel uses that are not big enough for a file
//! of their own: constants from 9/port/lib.h, runes, cleanname.
//!
//! DIFF: strings are slices.  Where the C edits a NUL-terminated string
//! in place, the Zig takes a buffer and returns the length used.

const std = @import("std");

pub const UTFmax = 4; // maximum bytes per rune
pub const Runeself = 0x80; // rune and UTF sequences are the same (<)
pub const Runeerror = 0xFFFD; // decoding error in UTF
pub const Runemax = 0x10FFFF; // 21 bit rune

pub const Rune = u21;

// open and create modes
pub const OREAD = 0; // open for read
pub const OWRITE = 1; // write
pub const ORDWR = 2; // read and write
pub const OEXEC = 3; // execute, == read but check execute permission
pub const OTRUNC = 16; // or'ed in (except for exec), truncate file first
pub const OCEXEC = 32; // or'ed in (per file descriptor), close on exec
pub const ORCLOSE = 64; // or'ed in, remove on close
pub const OEXCL = 0x1000; // or'ed in, exclusive create

// bind and mount flags
pub const MORDER = 0x0003; // mask for bits defining order of mounting
pub const MREPL = 0x0000; // mount replaces object
pub const MBEFORE = 0x0001; // mount goes before others in union directory
pub const MAFTER = 0x0002; // mount goes after others in union directory
pub const MCREATE = 0x0004; // permit creation in mounted directory
pub const MCACHE = 0x0010; // cache some data
pub const MMASK = 0x0017; // all bits on

/// The rune at the start of `s` and how many bytes it takes.  Bad UTF
/// decodes as Runeerror, one byte long, as chartorune does.
pub fn chartorune(s: []const u8) struct { r: Rune, n: usize } {
    if (s.len == 0) return .{ .r = Runeerror, .n = 0 };
    if (s[0] < Runeself) return .{ .r = s[0], .n = 1 };
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .r = Runeerror, .n = 1 };
    if (n > s.len) return .{ .r = Runeerror, .n = 1 };
    const r = std.unicode.utf8Decode(s[0..n]) catch return .{ .r = Runeerror, .n = 1 };
    return .{ .r = r, .n = n };
}

/// Number of runes in `s`.
pub fn utflen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += chartorune(s[i..]).n;
    return n;
}

fn sep(name: []const u8, i: usize) bool {
    return i >= name.len or name[i] == '/';
}

/// In place, rewrite name to compress multiple /, eliminate ., and
/// process ..  Returns the new length.  `buf` must have room for two
/// more bytes than the name, which the #x case can need.
/// from libc/port/cleanname.c
pub fn cleanname(buf: []u8, len: usize) usize {
    const name = buf[0..len];
    const rooted: usize = @intFromBool(len > 0 and name[0] == '/');
    var erasedprefix = false;

    // invariants:
    //  p points at beginning of path element we're considering.
    //  q points just past the last path element we wrote (no slash).
    //  dotdot points just past the point where .. cannot backtrack
    //      any further (no slash).
    var p: usize = rooted;
    var q: usize = rooted;
    var dotdot: usize = rooted;
    while (p < len) {
        if (name[p] == '/') { // null element
            p += 1;
        } else if (name[p] == '.' and sep(name, p + 1)) {
            if (p == 0)
                erasedprefix = true;
            p += 1; // don't count the separator in case it is nul
        } else if (name[p] == '.' and p + 1 < len and name[p + 1] == '.' and sep(name, p + 2)) {
            p += 2;
            if (q > dotdot) { // can backtrack
                q -= 1;
                while (q > dotdot and name[q] != '/') q -= 1;
            } else if (rooted == 0) { // /.. is / but ./../ is ..
                if (q != 0) {
                    buf[q] = '/';
                    q += 1;
                }
                buf[q] = '.';
                buf[q + 1] = '.';
                q += 2;
                dotdot = q;
            }
            if (q == 0)
                erasedprefix = true; // erased entire path via dotdot
        } else { // real path element
            if (q != rooted) {
                buf[q] = '/';
                q += 1;
            }
            while (p < len and name[p] != '/') {
                buf[q] = name[p];
                p += 1;
                q += 1;
            }
        }
    }
    if (q == 0) { // empty string is really ``.''
        buf[q] = '.';
        q += 1;
    }
    if (erasedprefix and buf[0] == '#') {
        // this was not a #x device path originally - make it not one now
        std.mem.copyBackwards(u8, buf[2 .. q + 2], buf[0..q]);
        buf[0] = '.';
        buf[1] = '/';
        q += 2;
    }
    return q;
}

fn clean(comptime s: []const u8) ![]const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    @memcpy(S.buf[0..s.len], s);
    return S.buf[0..cleanname(&S.buf, s.len)];
}

test "cleanname" {
    const eq = std.testing.expectEqualStrings;
    try eq("/", try clean("/"));
    try eq("/", try clean("//"));
    try eq("/a/b", try clean("/a//b/"));
    try eq("/a/c", try clean("/a/b/../c"));
    try eq("/", try clean("/.."));
    try eq("..", try clean("./.."));
    try eq("../a", try clean("../a"));
    try eq("../..", try clean("../.."));
    try eq(".", try clean("a/.."));
    try eq(".", try clean(""));
    try eq("a/b", try clean("./a/./b/."));
    try eq("#", try clean("#/"));
    try eq("./#c", try clean("./#c"));
    try eq("/usr/glenda", try clean("/usr/glenda/lib/.."));
}

test "runes" {
    try std.testing.expectEqual(@as(Rune, 'a'), chartorune("abc").r);
    const e = chartorune("€x");
    try std.testing.expectEqual(@as(Rune, 0x20ac), e.r);
    try std.testing.expectEqual(@as(usize, 3), e.n);
    try std.testing.expectEqual(@as(Rune, Runeerror), chartorune("\xff").r);
    try std.testing.expectEqual(@as(usize, 3), utflen("a€b"));
}
