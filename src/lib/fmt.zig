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
//! p (address), r (current error string), % (literal).
//! Flags: - + # space , 0, width and .precision, either may be `*`.
//!
//! A type can format itself for any verb by declaring
//!     pub fn fmt9(self: T, f: *Fmt) void
//! which is what fmtinstall does in C (%E, %I, %V ... in the kernel).

const std = @import("std");

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
        var sp: Spec = .{};
        var i = start;
        var dot = false;
        // Flags, width, precision and size modifiers, in any order.
        while (true) : (i += 1) {
            if (i >= format.len) @compileError("fmt: incomplete verb in \"" ++ format ++ "\"");
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

fn sfmt(f: *Fmt, s: []const u8) void {
    f.pad(if (f.flags.prec) runeprefix(s, f.prec) else s);
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
