//! Plan 9 formatted output: print("%s %lud %#p\n", ...).
//! from libc/fmt (dofmt.c, fmtquote.c)
//!
//! Format strings keep the Plan 9 verbs so ported code can keep its
//! print statements and so text that programs parse (/proc, /dev) comes
//! out byte for byte.
//!
//! DIFF: the format string is parsed at compile time and arguments are
//! typed, so the size modifiers (h, hh, l, ll) are accepted and ignored;
//! the argument's own type gives its width.  The `u` modifier still
//! matters: without it a negative value prints with a minus sign, with it
//! the value prints as the unsigned number of the same width.
//!
//! Verbs: d x X o b (integers), c and C (rune), s (string), q (quoted string),
//! e f g E G (floating point, from fltfmt.c),
//! p (address), r (current error string), % (literal).
//! Flags: - + # space , 0, width and .precision, either may be `*`.
//!
//! A type can format itself for any verb by declaring
//!     pub fn fmt9(self: T, f: *Fmt) void
//! which is what fmtinstall does in C (%E, %I, %V ... in the kernel).

const std = @import("std");
pub const flt = @import("flt.zig");

pub const Flags = packed struct {
    width: bool = false, // FmtWidth
    left: bool = false, // FmtLeft
    prec: bool = false, // FmtPrec
    sharp: bool = false, // FmtSharp
    space: bool = false, // FmtSpace
    sign: bool = false, // FmtSign
    zero: bool = false, // FmtZero
    unsigned: bool = false, // FmtUnsigned
    comma: bool = false, // FmtComma
};

pub const Fmt = struct {
    /// Output buffer.
    buf: []u8,
    /// Bytes of `buf` in use.
    n: usize = 0,
    /// Called when `buf` is full; must consume `buf[0..n]` and set `n` to 0.
    /// Without it, output that does not fit is dropped.
    flush: ?*const fn (*Fmt) void = null,
    /// For the flush routine.
    farg: ?*anyopaque = null,

    // State of the verb being formatted.
    flags: Flags = .{},
    width: usize = 0,
    prec: usize = 0,
    /// The verb character.
    r: u8 = 0,

    pub fn putc(f: *Fmt, c: u8) void {
        if (f.n == f.buf.len) {
            const fl = f.flush orelse return;
            fl(f);
            if (f.n == f.buf.len) return;
        }
        f.buf[f.n] = c;
        f.n += 1;
    }

    pub fn puts(f: *Fmt, s: []const u8) void {
        for (s) |c| f.putc(c);
    }

    fn putn(f: *Fmt, c: u8, n: usize) void {
        for (0..n) |_| f.putc(c);
    }

    /// Emit `s` padded to the current width; fmtstrcpy without the
    /// precision handling.  Width counts runes, not bytes.
    pub fn pad(f: *Fmt, s: []const u8) void {
        const nr = runelen(s);
        const fill = if (f.flags.width and f.width > nr) f.width - nr else 0;
        if (!f.flags.left) f.putn(' ', fill);
        f.puts(s);
        if (f.flags.left) f.putn(' ', fill);
    }

    /// Format further text into the same output from inside a fmt9 method.
    pub fn print(f: *Fmt, comptime format: []const u8, args: anytype) void {
        const save = .{ f.flags, f.width, f.prec, f.r };
        fmtprint(f, format, args);
        f.flags, f.width, f.prec, f.r = save;
    }
};

/// Source of the text for %r; the kernel points it at up->errstr.
pub var errstr: ?*const fn () []const u8 = null;

/// The C's doquote: besides white space and ', the characters %q
/// quotes.  The kernel leaves it null; user programs' start-up sets it
/// to needsrcquote, as libc/port/quote.c does.
pub var doquote: ?*const fn (u8) bool = null;

fn runelen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// The first `nr` runes of `s`.
fn runeprefix(s: []const u8, nr: usize) []const u8 {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 != 0x80) {
            if (n == nr) return s[0..i];
            n += 1;
        }
    }
    return s;
}

/// Format into `buf`; returns the part of `buf` written.  Output that
/// does not fit is dropped.
pub fn snprint(buf: []u8, comptime format: []const u8, args: anytype) []u8 {
    var f: Fmt = .{ .buf = buf };
    fmtprint(&f, format, args);
    return buf[0..f.n];
}

/// One verb of a format string, as parsed at compile time.
const Spec = struct {
    flags: Flags = .{},
    width: usize = 0,
    prec: usize = 0,
    /// Width and precision given as `*`: taken from the arguments.
    wstar: bool = false,
    pstar: bool = false,
    r: u8 = 0,
    /// Index of the first character after the verb.
    end: usize = 0,
};

/// Parse the verb whose '%' is at format[start-1].
fn parseSpec(comptime format: []const u8, comptime start: usize) Spec {
    comptime {
        return parseSpecAt(format, start) orelse
            @compileError("fmt: incomplete verb in \"" ++ format ++ "\"");
    }
}

/// Parse the verb whose '%' is at format[start-1], at compile time or
/// at run time; null if the format ends first.
fn parseSpecAt(format: []const u8, start: usize) ?Spec {
    {
        var sp: Spec = .{};
        var i = start;
        var dot = false;
        // Flags, width, precision and size modifiers, in any order.
        while (true) : (i += 1) {
            if (i >= format.len) return null;
            switch (format[i]) {
                '-' => sp.flags.left = true,
                '+' => sp.flags.sign = true,
                '#' => sp.flags.sharp = true,
                ' ' => sp.flags.space = true,
                ',' => sp.flags.comma = true,
                'u' => sp.flags.unsigned = true,
                'h', 'l' => {},
                '.' => {
                    dot = true;
                    sp.flags.prec = true;
                },
                '0'...'9' => |c| {
                    if (c == '0' and !dot) {
                        sp.flags.zero = true;
                        continue;
                    }
                    var v: usize = 0;
                    while (i < format.len and std.ascii.isDigit(format[i])) : (i += 1)
                        v = v * 10 + (format[i] - '0');
                    i -= 1;
                    if (dot) {
                        sp.prec = v;
                    } else {
                        sp.width = v;
                        sp.flags.width = true;
                    }
                },
                '*' => if (dot) {
                    sp.pstar = true;
                } else {
                    sp.wstar = true;
                },
                else => break,
            }
        }
        sp.r = format[i];
        sp.end = i + 1;
        return sp;
    }
}

pub fn fmtprint(f: *Fmt, comptime format: []const u8, args: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_names;
    const few = "fmt: too few arguments for \"" ++ format ++ "\"";
    comptime var i: usize = 0;
    comptime var argi: usize = 0;

    inline while (i < format.len) {
        // Literal text up to the next verb.
        const lit = comptime std.mem.findScalarPos(u8, format, i, '%') orelse format.len;
        if (lit > i) f.puts(format[i..lit]);
        if (lit >= format.len) break;

        const sp = comptime parseSpec(format, lit + 1);
        i = sp.end;
        f.flags = sp.flags;
        f.width = sp.width;
        f.prec = sp.prec;
        f.r = sp.r;

        if (sp.wstar) {
            if (argi >= fields.len) @compileError(few);
            const v: isize = @intCast(@field(args, fields[argi]));
            argi += 1;
            f.flags.width = true;
            f.flags.left = f.flags.left or v < 0;
            f.width = @abs(v);
        }
        if (sp.pstar) {
            if (argi >= fields.len) @compileError(few);
            const v: isize = @intCast(@field(args, fields[argi]));
            argi += 1;
            // A negative precision means none.
            if (v < 0) f.flags.prec = false else f.prec = @intCast(v);
        }

        switch (sp.r) {
            '%' => f.putc('%'),
            'r' => f.pad(if (errstr) |e| e() else "no error"),
            else => {
                if (argi >= fields.len) @compileError(few);
                verb(f, sp.r, @field(args, fields[argi]));
                argi += 1;
            },
        }
    }
    if (argi != fields.len) @compileError("fmt: too many arguments for \"" ++ format ++ "\"");
}

fn hasFmt9(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "fmt9"),
        .pointer => |p| p.size == .one and hasFmt9(p.child),
        else => false,
    };
}

fn verb(f: *Fmt, comptime r: u8, arg: anytype) void {
    const T = @TypeOf(arg);
    if (comptime hasFmt9(T)) return arg.fmt9(f);
    switch (r) {
        'd', 'x', 'X', 'o', 'b' => ifmt(f, r, arg),
        'e', 'f', 'g', 'E', 'G' => floatfmt(f, r, floatarg(arg)),
        'p' => {
            f.flags.unsigned = true;
            f.r = 'x';
            ifmt(f, 'x', if (@typeInfo(T) == .optional) @intFromPtr(arg) else arg);
        },
        'c', 'C' => {
            var buf: [4]u8 = undefined;
            f.pad(buf[0..runetochar(&buf, runearg(arg))]);
        },
        's' => sfmt(f, str(arg)),
        'q' => qfmt(f, str(arg)),
        else => @compileError("fmt: unknown verb %" ++ [1]u8{r} ++ " for " ++ @typeName(T)),
    }
}

/// libc's runetochar: as Zig's encoder, but surrogates are encoded like
/// any other rune, and a value past Runemax (0x10FFFF) is Runeerror.
/// DIFF: the C's %C takes the int argument as a Rune (32 bits); so does
/// this.
fn runetochar(buf: *[4]u8, r: u32) usize {
    const c: u32 = if (r > 0x10FFFF) 0xFFFD else r;
    if (c <= 0x7F) {
        buf[0] = @intCast(c);
        return 1;
    }
    if (c <= 0x7FF) {
        buf[0] = @intCast(0xC0 | (c >> 6));
        buf[1] = @intCast(0x80 | (c & 0x3F));
        return 2;
    }
    if (c <= 0xFFFF) {
        buf[0] = @intCast(0xE0 | (c >> 12));
        buf[1] = @intCast(0x80 | ((c >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (c & 0x3F));
        return 3;
    }
    buf[0] = @intCast(0xF0 | (c >> 18));
    buf[1] = @intCast(0x80 | ((c >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((c >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (c & 0x3F));
    return 4;
}

/// An integer argument of %c or %C as the C's 32-bit Rune.
fn runearg(arg: anytype) u32 {
    return switch (@typeInfo(@TypeOf(arg))) {
        .comptime_int => arg,
        .int => |i| if (i.signedness == .signed)
            @truncate(@as(u64, @bitCast(@as(i64, arg))))
        else
            @truncate(@as(u64, arg)),
        else => @compileError("fmt: %C needs an integer, got " ++ @typeName(@TypeOf(arg))),
    };
}

/// Any of the ways Zig spells a string, as a slice; null prints as <nil>.
fn str(arg: anytype) []const u8 {
    const T = @TypeOf(arg);
    switch (@typeInfo(T)) {
        .optional => return if (arg) |a| str(a) else "<nil>",
        .pointer => |p| switch (p.size) {
            .slice => return arg,
            .one => return arg, // pointer to array
            .many, .c => return std.mem.span(@as([*:0]const u8, @ptrCast(arg))),
        },
        .array => return &arg,
        else => @compileError("fmt: %s needs a string, got " ++ @typeName(T)),
    }
}

/// %s: fmtstrcpy and _fmtcpy.  Each rune is decoded and encoded again,
/// so a byte that is not UTF-8 prints as Runeerror, and an incomplete
/// sequence at the end of the string is left out.  Width and precision
/// count runes as chartorune decodes them.
fn sfmt(f: *Fmt, s_: []const u8) void {
    var s = s_;
    var n: usize = 0;
    if (f.flags.prec) {
        var i: usize = 0;
        while (n < f.prec and i < s.len) : (n += 1)
            i += chartorune(s, i).n;
        s = s[0..@min(i, s.len)];
    } else {
        var i: usize = 0;
        while (i < s.len) : (n += 1)
            i += chartorune(s, i).n;
    }
    const fill = if (f.flags.width and f.width > n) f.width - n else 0;
    if (!f.flags.left) f.putn(' ', fill);
    var m: usize = 0;
    var nc = n;
    while (nc > 0) : (nc -= 1) {
        if (m >= s.len) break;
        if (s[m] < 0x80) {
            f.putc(s[m]);
            m += 1;
            continue;
        }
        if (s.len - m < 4 and !fullrune(s[m..]))
            break;
        const d = chartorune(s, m);
        m += d.n;
        var buf: [4]u8 = undefined;
        f.puts(buf[0..runetochar(&buf, d.r)]);
    }
    if (f.flags.left) f.putn(' ', fill);
}

/// libc's fullrune.
fn fullrune(s: []const u8) bool {
    if (s.len == 0) return false;
    const c = s[0];
    if (c < 0x80) return true;
    if (c < 0xE0) return s.len >= 2;
    if (c < 0xF0) return s.len >= 3;
    return s.len >= 4;
}

/// libc's chartorune at s[i..]: surrogates decode, anything else that
/// is not UTF-8 is Runeerror, one byte long.  Past the end reads as the
/// C string's 0.
const Decoded = struct { r: u32, n: usize };

fn chartorune(s: []const u8, i: usize) Decoded {
    const S = struct {
        fn at(b: []const u8, k: usize) u32 {
            return if (k < b.len) b[k] else 0;
        }
    };
    const bad: Decoded = .{ .r = 0xFFFD, .n = 1 };
    const c = S.at(s, i);
    if (c < 0x80) return .{ .r = c, .n = 1 };
    const c1 = S.at(s, i + 1) ^ 0x80;
    if (c1 & 0xC0 != 0) return bad;
    if (c < 0xE0) {
        if (c < 0xC0) return bad;
        const l = ((c << 6) | c1) & 0x7FF;
        if (l <= 0x7F) return bad;
        return .{ .r = l, .n = 2 };
    }
    const c2 = S.at(s, i + 2) ^ 0x80;
    if (c2 & 0xC0 != 0) return bad;
    if (c < 0xF0) {
        const l = ((((c << 6) | c1) << 6) | c2) & 0xFFFF;
        if (l <= 0x7FF) return bad;
        return .{ .r = l, .n = 3 };
    }
    const c3 = S.at(s, i + 3) ^ 0x80;
    if (c3 & 0xC0 != 0) return bad;
    if (c < 0xF8) {
        const l = ((((((c << 6) | c1) << 6) | c2) << 6) | c3) & 0x1FFFFF;
        if (l <= 0xFFFF or l > 0x10FFFF) return bad;
        return .{ .r = l, .n = 4 };
    }
    return bad;
}

/// %q: quote the string rc-style if it is empty or has white space or
/// quotes in it; %#q: always.
fn qfmt(f: *Fmt, full: []const u8) void {
    const s = if (f.flags.prec) runeprefix(full, f.prec) else full;
    // %#q always quotes.
    var quote = s.len == 0 or f.flags.sharp;
    var nq: usize = 0;
    for (s) |c| {
        if (c <= ' ' or c == '\'') quote = true;
        if (doquote) |dq| {
            if (dq(c)) quote = true;
        }
        if (c == '\'') nq += 1;
    }
    if (!quote) return f.pad(s);

    const nr = runelen(s) + nq + 2;
    const fill = if (f.flags.width and f.width > nr) f.width - nr else 0;
    if (!f.flags.left) f.putn(' ', fill);
    f.putc('\'');
    for (s) |c| {
        if (c == '\'') f.putc('\'');
        f.putc(c);
    }
    f.putc('\'');
    if (f.flags.left) f.putn(' ', fill);
}

fn ifmt(f: *Fmt, comptime r: u8, arg: anytype) void {
    const T = @TypeOf(arg);
    var neg = false;
    var vu: u64 = undefined;
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits > 64) @compileError("fmt: integer too wide: " ++ @typeName(T));
            if (info.signedness == .signed) {
                if (f.flags.unsigned) {
                    const U = @Int(.unsigned, info.bits);
                    vu = @as(U, @bitCast(arg));
                } else {
                    neg = arg < 0;
                    vu = @abs(@as(i64, arg));
                }
            } else vu = arg;
        },
        .comptime_int => {
            if (arg < 0) {
                if (f.flags.unsigned) {
                    // What C would do with an int constant.
                    vu = if (arg >= std.math.minInt(i32))
                        @as(u32, @bitCast(@as(i32, arg)))
                    else
                        @bitCast(@as(i64, arg));
                } else {
                    neg = true;
                    vu = -arg;
                }
            } else vu = arg;
        },
        .bool => vu = @intFromBool(arg),
        .@"enum" => return ifmt(f, r, @backingInt(arg)),
        .pointer => vu = @intFromPtr(arg),
        .optional => vu = @intFromPtr(arg),
        else => @compileError("fmt: %" ++ [1]u8{r} ++ " needs an integer, got " ++ @typeName(T)),
    }

    const base: u64 = switch (r) {
        'd' => 10,
        'x', 'X' => 16,
        'o' => 8,
        'b' => 2,
        else => unreachable,
    };
    const conv = if (r == 'X') "0123456789ABCDEF" else "0123456789abcdef";

    // Built right to left, as in _ifmt.
    var buf: [96]u8 = undefined;
    var p: usize = buf.len;
    var n: usize = 0;
    while (vu != 0) {
        if (f.flags.comma and n % 4 == 3) {
            p -= 1;
            buf[p] = ',';
            n += 1;
        }
        p -= 1;
        buf[p] = conv[@intCast(vu % base)];
        vu /= base;
        n += 1;
    }
    if (n == 0) {
        p -= 1;
        buf[p] = '0';
        n = 1;
    }
    while (n < f.prec and p > 4) : (n += 1) {
        p -= 1;
        buf[p] = '0';
    }
    if (neg or f.flags.sign or f.flags.space) n += 1;
    var sharp = f.flags.sharp;
    if (sharp) {
        if (base == 16) {
            n += 2;
        } else if (base == 8) {
            if (buf[p] == '0') sharp = false else n += 1;
        }
    }
    if (f.flags.zero and !f.flags.left and !f.flags.prec) {
        while (n < f.width and p > 4) : (n += 1) {
            p -= 1;
            buf[p] = '0';
        }
        f.width = 0;
    }
    if (sharp) {
        if (base == 16) {
            p -= 1;
            buf[p] = r;
        }
        if (base == 16 or base == 8) {
            p -= 1;
            buf[p] = '0';
        }
    }
    if (neg) {
        p -= 1;
        buf[p] = '-';
    } else if (f.flags.sign) {
        p -= 1;
        buf[p] = '+';
    } else if (f.flags.space) {
        p -= 1;
        buf[p] = ' ';
    }
    f.pad(buf[p..]);
}

fn expect(want: []const u8, comptime format: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(want, snprint(&buf, format, args));
}

test "integers" {
    try expect("0", "%d", .{0});
    try expect("-42", "%d", .{@as(i32, -42)});
    try expect("42 0x2a 52 101010", "%d %#x %o %b", .{ 42, 42, 42, 42 });
    try expect("ffffffff", "%ux", .{@as(i32, -1)});
    try expect("-1", "%x", .{@as(i32, -1)});
    try expect("ffffffffffffffff", "%llux", .{@as(i64, -1)});
    try expect("18446744073709551615", "%llud", .{@as(u64, std.math.maxInt(u64))});
    try expect("DEAD", "%X", .{0xdead});
    try expect("0XDEAD", "%#X", .{0xdead});
    try expect("+7", "%+d", .{7});
    try expect("100,000,000", "%,d", .{100000000});
}

test "width and precision" {
    try expect("   42|42   |00042", "%5d|%-5d|%05d", .{ 42, 42, 42 });
    try expect("  042", "%5.3d", .{42});
    try expect("0x0000002a", "%#.8x", .{42});
    try expect("0x00002a", "%#08x", .{42});
    try expect("  7|7  ", "%*d|%*d", .{ 3, 7, -3, 7 });
    try expect("-0042", "%05d", .{-42});
}

test "addresses" {
    try expect("ffffffff80110000", "%p", .{@as(usize, 0xffffffff80110000)});
    try expect("0xffffffff80110000", "%#p", .{@as(usize, 0xffffffff80110000)});
    try expect("0x0000000000001000", "%#.16p", .{@as(usize, 0x1000)});
}

test "strings" {
    const z: [*:0]const u8 = "nul";
    const none: ?[]const u8 = null;
    try expect("a slice, nul, <nil>", "%s, %s, %s", .{ @as([]const u8, "a slice"), z, none });
    try expect("[   hi][hi   ][he]", "[%5s][%-5s][%.2s]", .{ "hi", "hi", "hello" });
    try expect("abc", "%.*s", .{ 3, "abcdef" });
    try expect("[  é]", "[%3s]", .{"é"});
    try expect("x€", "%c%c", .{ 'x', 0x20ac });
    try expect("100%", "%d%%", .{100});
}

test "quoting" {
    try expect("plain", "%q", .{"plain"});
    try expect("''", "%q", .{""});
    try expect("'two words'", "%q", .{"two words"});
    try expect("'it''s'", "%q", .{"it's"});
    try expect("'plain'", "%#q", .{"plain"});
}

test "custom verb and flush" {
    const Ea = struct {
        a: [6]u8,
        pub fn fmt9(self: @This(), f: *Fmt) void {
            f.print("%.2x%.2x%.2x%.2x%.2x%.2x", .{ self.a[0], self.a[1], self.a[2], self.a[3], self.a[4], self.a[5] });
        }
    };
    try expect("ea 0050c2000102.", "ea %E.", .{Ea{ .a = .{ 0, 0x50, 0xc2, 0, 1, 2 } }});

    const Sink = struct {
        var out: [64]u8 = undefined;
        var n: usize = 0;
        fn flush(f: *Fmt) void {
            @memcpy(out[n..][0..f.n], f.buf[0..f.n]);
            n += f.n;
            f.n = 0;
        }
    };
    var small: [4]u8 = undefined;
    var f: Fmt = .{ .buf = &small, .flush = Sink.flush };
    fmtprint(&f, "%s %d", .{ "longer than four", 12345 });
    Sink.flush(&f);
    try std.testing.expectEqualStrings("longer than four 12345", Sink.out[0..Sink.n]);

    var tiny: [3]u8 = undefined;
    try std.testing.expectEqualStrings("tru", snprint(&tiny, "%s", .{"truncated"}));
}

test "error string" {
    try expect("open: no error", "open: %r", .{});
    errstr = struct {
        fn e() []const u8 {
            return "file does not exist";
        }
    }.e;
    defer errstr = null;
    try expect("open: file does not exist", "open: %r", .{});
}

test "%s re-encodes as Plan 9 does" {
    var buf: [64]u8 = undefined;
    // a bad byte is Runeerror; near the end it looks like the start of an
    // incomplete rune, which is left out with the rest, as in C
    try std.testing.expectEqualStrings("a\xef\xbf\xbdbcde", snprint(&buf, "%s", .{"a\xffbcde"}));
    try std.testing.expectEqualStrings("a", snprint(&buf, "%s", .{"a\xffb"}));
    try std.testing.expectEqualStrings("a", snprint(&buf, "%s", .{"a\xe6\x97"}));
    try std.testing.expectEqualStrings("[日本 ]", snprint(&buf, "[%-3s]", .{"日本"}));
    try std.testing.expectEqualStrings("日", snprint(&buf, "%.1s", .{"日本"}));
    // surrogates pass through
    try std.testing.expectEqualStrings("\xed\xa0\x80", snprint(&buf, "%s", .{"\xed\xa0\x80"}));
}

// --------------------------------------------------------- fltfmt.c

/// A %e %f %g argument as the C's double.
fn floatarg(arg: anytype) f64 {
    return switch (@typeInfo(@TypeOf(arg))) {
        .float, .comptime_float => @floatCast(arg),
        else => @compileError("fmt: %e %f %g need a float, got " ++ @typeName(@TypeOf(arg))),
    };
}

const FDIGIT = 30;
const FDEFLT = 6;
const NSIGNIF = 17;
const NEXP10 = 308;

/// Add v at digit n of a, carrying; true if it carried out of a[0].
fn xadd(a: []u8, n: i32, v: u8) bool {
    if (n < 0 or n >= NSIGNIF)
        return false;
    var b: usize = @intCast(n);
    var vv = v;
    while (true) : (b -= 1) {
        const c = a[b] + vv;
        if (c <= '9') {
            a[b] = c;
            return false;
        }
        a[b] = '0';
        vv = 1;
        if (b == 0) break;
    }
    a[0] = '1'; // overflow adding
    return true;
}

/// Subtract v at digit n of a, borrowing; true if it borrowed past a[0].
fn xsub(a: []u8, n: i32, v: u8) bool {
    var b: usize = @intCast(n);
    var vv = v;
    while (true) : (b -= 1) {
        const c = @as(i32, a[b]) - vv;
        if (c >= '0') {
            a[b] = @intCast(c);
            return false;
        }
        a[b] = '9';
        vv = 1;
        if (b == 0) break;
    }
    a[0] = '9'; // underflow subtracting
    return true;
}

/// The C's sprint(s1+NSIGNIF, "e%d", x); returns s1's new length.
fn setexp(s1: []u8, x: i32) usize {
    return NSIGNIF + snprint(s1[NSIGNIF..], "e%d", .{x}).len;
}

/// Format f into s2 as fmt's verb chr (e f g E G) asks; returns the part
/// of s2 used.  The C's xdtoa, step for step: 17 digits from a first
/// guess, corrected against strtod until they convert back to f, then
/// rounded and laid out for the verb.
fn xdtoa(fmt: *const Fmt, chr0: u8, f_: f64, s2: []u8) []u8 {
    var s1: [NSIGNIF + 10]u8 = undefined;
    var save: [NSIGNIF + 10]u8 = undefined;
    var f = f_;
    var prec: i32 = FDEFLT;
    if (fmt.flags.prec)
        prec = @intCast(@min(fmt.prec, std.math.maxInt(i32)));
    if (prec > FDIGIT)
        prec = FDIGIT;
    const sign = @as(u64, @bitCast(f)) >> 63 != 0;
    var ucase = false;
    var chr = chr0;
    const isnan = flt.isNaN(f);
    const isinf = flt.isInf(f, 0);
    var e: i32 = 0;
    var n1: usize = NSIGNIF; // s1's length with its exponent

    found: {
        if (isnan or isinf)
            break :found;
        if (sign)
            f = -f;
        if (std.ascii.isUpper(chr)) {
            ucase = true;
            chr = std.ascii.toLower(chr);
        }

        var g = f;
        if (g != 0) {
            e = flt.frexp(f).e;
            e = @intFromFloat(@as(f64, @floatFromInt(e)) * 0.301029995664);
            var d: i32 = undefined;
            var h: f64 = undefined;
            if (e >= -150 and e <= 150) {
                d = 0;
                h = f;
            } else {
                d = @divTrunc(e, 2);
                h = f * flt.pow10(-d);
            }
            g = h * flt.pow10(d - e);
            while (g < 1) {
                e -= 1;
                g = h * flt.pow10(d - e);
            }
            while (g >= 10) {
                e += 1;
                g = h * flt.pow10(d - e);
            }
        }

        // convert NSIGNIF digits and convert
        // back to get accuracy.
        for (0..NSIGNIF) |i| {
            const d: i32 = @intFromFloat(g);
            s1[i] = @intCast(d + '0');
            g = (g - @as(f64, @floatFromInt(d))) * 10;
        }

        // try decimal rounding to eliminate 9s
        var c2 = prec + 1;
        if (chr == 'f')
            c2 += e;
        if (c2 >= NSIGNIF - 2) {
            save = s1;
            const d = e;
            s1[NSIGNIF - 2] = '0';
            s1[NSIGNIF - 1] = '0';
            n1 = setexp(&s1, e - NSIGNIF + 1);
            g = flt.strtod(s1[0..n1]).v;
            if (g == f)
                break :found;
            if (xadd(&s1, NSIGNIF - 3, 1)) {
                e += 1;
                n1 = setexp(&s1, e - NSIGNIF + 1);
            }
            g = flt.strtod(s1[0..n1]).v;
            if (g == f)
                break :found;
            s1 = save;
            e = d;
        }

        // convert back so s1 gets exact answer
        while (true) {
            n1 = setexp(&s1, e - NSIGNIF + 1);
            g = flt.strtod(s1[0..n1]).v;
            if (f > g) {
                if (xadd(&s1, NSIGNIF - 1, 1))
                    e -= 1;
                continue;
            }
            if (f < g) {
                if (xsub(&s1, NSIGNIF - 1, 1))
                    e += 1;
                continue;
            }
            break;
        }
    }

    // sign
    var d: usize = 0;
    if (sign) {
        s2[d] = '-';
        d += 1;
    } else if (fmt.flags.sign) {
        s2[d] = '+';
        d += 1;
    } else if (fmt.flags.space) {
        s2[d] = ' ';
        d += 1;
    }

    if (isnan) {
        @memcpy(s2[d..][0..3], "NaN");
        return s2[0 .. d + 3];
    }
    if (isinf) {
        @memcpy(s2[d..][0..3], "Inf");
        return s2[0 .. d + 3];
    }

    // copy into final place
    // c1 digits of leading '0'
    // c2 digits from conversion
    // c3 digits of trailing '0'
    // c4 digits after '.'
    if (chr == 'g' and prec > 0) // Significant figures.
        prec -= 1;
    var c1: i32 = 0;
    var c2: i32 = prec + 1;
    var c3: i32 = 0;
    var c4: i32 = prec;
    switch (chr) {
        'g' => {
            // decide on 'e' of 'f' style convers
            if (xadd(&s1, c2, 5))
                e += 1;
            if (e >= -4 and e <= prec) {
                c1 = -e;
                c4 = prec - e;
                chr = 'h'; // flag for 'f' style
            }
        },
        'f' => {
            if (xadd(&s1, c2 + e, 5))
                e += 1;
            c1 = -e;
            if (c1 > prec)
                c1 = c2;
            c2 += e;
        },
        else => {
            if (xadd(&s1, c2, 5))
                e += 1;
        },
    }

    // clean up c1 c2 and c3
    if (c1 < 0)
        c1 = 0;
    if (c2 < 0)
        c2 = 0;
    if (c2 > NSIGNIF) {
        c3 = c2 - NSIGNIF;
        c2 = NSIGNIF;
    }

    // copy digits
    var i: usize = 0;
    while (c1 > 0) : (c1 -= 1) {
        if (c1 + c2 + c3 == c4) {
            s2[d] = '.';
            d += 1;
        }
        s2[d] = '0';
        d += 1;
    }
    while (c2 > 0) : (c2 -= 1) {
        if (c2 + c3 == c4) {
            s2[d] = '.';
            d += 1;
        }
        s2[d] = s1[i];
        d += 1;
        i += 1;
    }
    while (c3 > 0) : (c3 -= 1) {
        if (c3 == c4) {
            s2[d] = '.';
            d += 1;
        }
        s2[d] = '0';
        d += 1;
    }

    // strip trailing '0' on g conv
    if (fmt.flags.sharp) {
        if (c4 == 0) {
            s2[d] = '.';
            d += 1;
        }
    } else if (chr == 'g' or chr == 'h') {
        var n: isize = @as(isize, @intCast(d)) - 1;
        while (n >= 0) : (n -= 1) {
            if (s2[@intCast(n)] != '0')
                break;
        }
        var k = n;
        while (k >= 0) : (k -= 1) {
            if (s2[@intCast(k)] == '.') {
                d = @intCast(n);
                if (k != n)
                    d += 1;
                break;
            }
        }
    }
    if (chr == 'e' or chr == 'g') {
        s2[d] = if (ucase) 'E' else 'e';
        d += 1;
        var x = e;
        if (x < 0) {
            s2[d] = '-';
            x = -x;
        } else s2[d] = '+';
        d += 1;
        if (x >= 100) {
            s2[d] = @intCast(@divTrunc(x, 100) + '0');
            d += 1;
            x = @mod(x, 100);
        }
        s2[d] = @intCast(@divTrunc(x, 10) + '0');
        s2[d + 1] = @intCast(@mod(x, 10) + '0');
        d += 2;
    }
    return s2[0..d];
}

/// _floatfmt: the number, then only width and '-' of the flags.
fn floatfmt(f: *Fmt, comptime r: u8, v: f64) void {
    var s: [1 + NEXP10 + 1 + FDIGIT + 1]u8 = undefined;
    const out = xdtoa(f, r, v, &s);
    const keep: Flags = .{ .width = f.flags.width, .left = f.flags.left };
    f.flags = keep;
    sfmt(f, out);
}

test "%e %f %g as 9front prints them" {
    var buf: [400]u8 = undefined;
    const T = struct {
        fn check(b: []u8, comptime format: []const u8, v: anytype, want: []const u8) !void {
            try std.testing.expectEqualStrings(want, snprint(b, format, .{v}));
        }
    };
    try T.check(&buf, "%g", 0.1, "0.1");
    try T.check(&buf, "%g", 100000.0, "100000");
    try T.check(&buf, "%g", 1000000.0, "1e+06");
    try T.check(&buf, "%g", 1.0e-5, "1e-05");
    try T.check(&buf, "%g", 0.0001, "0.0001");
    try T.check(&buf, "%f", 3.14159, "3.141590");
    try T.check(&buf, "%.2f", 2.675, "2.67");
    try T.check(&buf, "%.0f", 0.5, "1");
    try T.check(&buf, "%e", 12345.678, "1.234568e+04");
    try T.check(&buf, "%E", 1.0e-300, "1.000000E-300");
    try T.check(&buf, "%G", 1.5e300, "1.5E+300");
    try T.check(&buf, "%g", -0.0, "-0");
    try T.check(&buf, "%+g", 2.0, "+2");
    try T.check(&buf, "% g", 2.0, " 2");
    try T.check(&buf, "%#g", 2.0, "2.00000");
    try T.check(&buf, "%#.0f", 2.0, "2.");
    try T.check(&buf, "%05.1f", 2.25, "  2.3"); // half up on the decimal digits; 0 flag dropped
    try T.check(&buf, "%-8.3e|", 1.0, "1.000e+00|");
    try T.check(&buf, "%g", flt.NaN(), "NaN");
    try T.check(&buf, "%g", flt.Inf(-1), "-Inf");
    try T.check(&buf, "%.17g", 0.1, "0.1"); // the 9s step finds 0.1 reads back exactly
    try T.check(&buf, "%g", @as(f32, 0.5), "0.5");
}

test "%.17g reads back" {
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    var buf: [400]u8 = undefined;
    for (0..5000) |_| {
        const v: f64 = @bitCast(rnd.int(u64) & 0x7fef_ffff_ffff_ffff);
        const s = snprint(&buf, "%.17g", .{v});
        try std.testing.expectEqual(v, flt.strtod(s).v);
    }
}

// ------------------------------------------------- formats at run time

/// A value for runprint: the C's varargs, typed at run time.
pub const Value = union(enum) {
    int: i64,
    uint: u64,
    float: f64,
    str: []const u8,

    fn kind(v: Value) []const u8 {
        return @tagName(v);
    }
};

/// fmtprint with a format known only at run time (seq -f, say): the same
/// verbs, flags, width and precision, parsed as it goes.  A verb that does
/// not fit its value, undefined in C, prints %!v(kind); an unknown verb
/// prints %v% as the C's badfmt does; a value missing prints %!v(missing).
pub fn runprint(f: *Fmt, format: []const u8, args: []const Value) void {
    var i: usize = 0;
    var argi: usize = 0;
    while (i < format.len) {
        const lit = std.mem.findScalarPos(u8, format, i, '%') orelse format.len;
        if (lit > i) f.puts(format[i..lit]);
        if (lit >= format.len) break;

        const sp = parseSpecAt(format, lit + 1) orelse break; // a '%' at the end prints nothing
        i = sp.end;
        f.flags = sp.flags;
        f.width = sp.width;
        f.prec = sp.prec;
        f.r = sp.r;

        if (sp.wstar) {
            const v = starval(args, &argi);
            f.flags.width = true;
            f.flags.left = f.flags.left or v < 0;
            f.width = @abs(v);
        }
        if (sp.pstar) {
            const v = starval(args, &argi);
            if (v < 0) f.flags.prec = false else f.prec = @intCast(v);
        }

        switch (sp.r) {
            '%' => f.putc('%'),
            'r' => f.pad(if (errstr) |e| e() else "no error"),
            'd', 'x', 'X', 'o', 'b', 'c', 'C', 'p', 's', 'q', 'e', 'f', 'g', 'E', 'G' => {
                if (argi >= args.len) {
                    badval(f, sp.r, "missing");
                    continue;
                }
                runverb(f, sp.r, args[argi]);
                argi += 1;
            },
            else => badfmt(f, sp.r),
        }
    }
}

/// Format into buf at run time; returns the part of buf written.
pub fn runsnprint(buf: []u8, format: []const u8, args: []const Value) []u8 {
    var f: Fmt = .{ .buf = buf };
    runprint(&f, format, args);
    return buf[0..f.n];
}

fn starval(args: []const Value, argi: *usize) i64 {
    if (argi.* >= args.len) return 0;
    const v = args[argi.*];
    argi.* += 1;
    return switch (v) {
        .int => |x| x,
        .uint => |x| @bitCast(x),
        else => 0,
    };
}

fn badval(f: *Fmt, r: u8, what: []const u8) void {
    f.flags = .{};
    f.puts("%!");
    f.putc(r);
    f.putc('(');
    f.puts(what);
    f.putc(')');
}

fn runverb(f: *Fmt, r: u8, v: Value) void {
    switch (r) {
        inline 'd', 'x', 'X', 'o', 'b', 'c', 'C', 'p' => |c| switch (v) {
            .int => |x| verb(f, c, x),
            .uint => |x| verb(f, c, x),
            else => badval(f, r, v.kind()),
        },
        's' => switch (v) {
            .str => |x| sfmt(f, x),
            else => badval(f, r, v.kind()),
        },
        'q' => switch (v) {
            .str => |x| qfmt(f, x),
            else => badval(f, r, v.kind()),
        },
        inline 'e', 'f', 'g', 'E', 'G' => |c| switch (v) {
            .float => |x| floatfmt(f, c, x),
            else => badval(f, r, v.kind()),
        },
        else => badfmt(f, r),
    }
}

/// _badfmt: "%" r "%", copied as a string of that precision; it takes
/// no argument.
fn badfmt(f: *Fmt, r: u8) void {
    var x: [3]u8 = .{ '%', r, '%' };
    f.flags.prec = true;
    f.prec = 3;
    sfmt(f, &x);
}

test "formats at run time" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("x=  42 0x1f 2.50 'a b' %", runsnprint(&buf, "x=%4d %#x %.2f %q %%", &.{ .{ .int = 42 }, .{ .uint = 31 }, .{ .float = 2.5 }, .{ .str = "a b" } }));
    try std.testing.expectEqualStrings("[  1.5]", runsnprint(&buf, "[%*.*f]", &.{ .{ .int = 5 }, .{ .int = 1 }, .{ .float = 1.5 } }));
    try std.testing.expectEqualStrings("%!f(str) %!d(missing) %z%", runsnprint(&buf, "%f %d %z", &.{.{ .str = "x" }}));
    try std.testing.expectEqualStrings("ab", runsnprint(&buf, "ab%", &.{}));
}

