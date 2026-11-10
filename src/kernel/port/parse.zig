//! Parsing of the control messages written to devices.
//! from 9/port/parse.c; Cmdbuf and Cmdtab are from 9/port/portdat.h,
//! tokenize and qtoken from libc/port/tokenize.c.
//!
//! DIFF:
//!   - parsecmd takes a slice of kernel memory, where the C copies from
//!     an address that may be the user's.  The waserror that freed the
//!     Cmdbuf if that copy faulted is gone with it; copying a control
//!     message in from user memory is the caller's job.
//!   - Fields are slices of Cmdbuf.buf and Cmdbuf.f has exactly nf
//!     entries, so there is no terminating nil pointer and ncmdfield
//!     does not count one.  The Cmdbuf, the fields and the copy of the
//!     text are still one allocation, freed with free(cb).
//!   - A NUL in the message ends it, as it does for the C's string
//!     functions; here that has to be done explicitly.
//!   - The body of parsecmd after the allocation is cmdfill, so that it
//!     can be tested without the kernel allocator.
//!   - cmderror returns the error for the caller to return (it cannot
//!     longjmp), and lookupcmd returns an error union.  Both set the
//!     text with proc.errorf, so the error is error.Str.
//!   - lookupcmd takes the table as one slice.
//!   - tokenize is here because nothing else in the kernel has needed
//!     it yet.  It takes the string as a slice and returns slices.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const errmod = @import("error.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");

pub const Error = errmod.Error;

pub const Cmdbuf = struct {
    /// The text of the message, without its final newline.  tokenize
    /// has edited it in place: quotes are gone.
    buf: []u8,
    /// The fields, f.len == nf.
    f: [][]u8,
    nf: usize,
};

pub const Cmdtab = struct {
    index: i32, // used by client to switch on result
    cmd: []const u8, // command name
    narg: usize = 0, // expected #args; 0 ==> variadic
};

const qsep = " \t\r\n";

fn issep(c: u8) bool {
    return std.mem.findScalar(u8, qsep, c) != null;
}

/// Take the token that starts at buf[start], removing its quotes in
/// place.  Returns where the token now ends and where to look for the
/// next one.
fn qtoken(buf: []u8, start: usize) struct { end: usize, next: usize } {
    var quoting = false;
    var s = start; // s is output string, t is input string
    var t = start;
    while (t < buf.len and (quoting or !issep(buf[t]))) {
        if (buf[t] != '\'') {
            buf[s] = buf[t];
            s += 1;
            t += 1;
            continue;
        }
        // buf[t] is a quote
        if (!quoting) {
            quoting = true;
            t += 1;
            continue;
        }
        // quoting and we're on a quote
        if (t + 1 >= buf.len or buf[t + 1] != '\'') {
            // end of quoted section; absorb closing quote
            t += 1;
            quoting = false;
            continue;
        }
        // doubled quote; fold one quote into two
        t += 1;
        buf[s] = buf[t];
        s += 1;
        t += 1;
    }
    const end = s;
    if (s < buf.len) {
        buf[s] = 0;
        if (t == s)
            t += 1;
    }
    return .{ .end = end, .next = t };
}

/// Split s into at most args.len fields separated by white space, with
/// rc-style quoting.  The fields are slices of s, which is edited in
/// place.  Returns the number of fields.
/// from libc/port/tokenize.c
pub fn tokenize(s: []u8, args: [][]u8) usize {
    var p: usize = 0;
    var nargs: usize = 0;
    while (nargs < args.len) : (nargs += 1) {
        while (p < s.len and issep(s[p]))
            p += 1;
        if (p >= s.len)
            break;
        const r = qtoken(s, p);
        args[nargs] = s[p..r.end];
        p = r.next;
    }
    return nargs;
}

/// Generous estimate of number of fields
fn ncmdfield(p: []const u8) usize {
    var nf: usize = 0;
    var white = true; // first text will start field
    for (p) |c| {
        const nwhite = issep(c); // UTF is irrelevant
        if (white and !nwhite) // beginning of field
            nf += 1;
        white = nwhite;
    }
    return nf;
}

/// Lay out a Cmdbuf in the memory at sp, which has room for the Cmdbuf,
/// nf fields and a copy of p, and parse p into it.
fn cmdfill(sp: [*]align(@alignOf(Cmdbuf)) u8, p: []const u8, nf: usize) *Cmdbuf {
    var n = p.len;
    const cb: *Cmdbuf = @ptrCast(sp);
    const f: [*][]u8 = @ptrCast(@alignCast(sp + @sizeOf(Cmdbuf)));
    const buf = sp + @sizeOf(Cmdbuf) + nf * @sizeOf([]u8);

    @memcpy(buf[0..n], p);

    // dump new line and null terminate
    if (n > 0 and buf[n - 1] == '\n')
        n -= 1;
    if (std.mem.findScalar(u8, buf[0..n], 0)) |i|
        n = i;
    cb.buf = buf[0..n];

    cb.nf = tokenize(cb.buf, f[0..nf]);
    cb.f = f[0..cb.nf];

    return cb;
}

/// parse a command written to a device
pub fn parsecmd(p: []const u8) Error!*Cmdbuf {
    if (arch.up() != null and p.len > portdat.READSTR)
        return proc.errorf("control message too big", .{});

    const nf = ncmdfield(p);

    // allocate Cmdbuf plus string pointers plus copy of string
    const sp = alloc.smalloc(@sizeOf(Cmdbuf) + nf * @sizeOf([]u8) + p.len);
    return cmdfill(@alignCast(sp), p, nf);
}

/// Reconstruct original message, for error diagnostic
pub fn cmderror(cb: *const Cmdbuf, s: []const u8) Error {
    const up = arch.up().?;
    var f: fmt.Fmt = .{ .buf = up.genbuf[0 .. portdat.ERRMAX - 10 - 1] };
    fmt.fmtprint(&f, "%s \"", .{s});
    for (cb.f, 0..) |a, i| {
        if (i > 0)
            fmt.fmtprint(&f, " ", .{});
        fmt.fmtprint(&f, "%q", .{a});
    }
    up.genbuf[f.n] = '"';
    return proc.errorf("%s", .{up.genbuf[0 .. f.n + 1]});
}

/// Look up entry in table
pub fn lookupcmd(cb: *const Cmdbuf, ctab: []const Cmdtab) Error!*const Cmdtab {
    if (cb.nf == 0)
        return proc.errorf("empty control message", .{});

    for (ctab) |*ct| {
        if (!std.mem.eql(u8, ct.cmd, "*")) // wildcard always matches
            if (!std.mem.eql(u8, ct.cmd, cb.f[0]))
                continue;
        if (ct.narg != 0 and ct.narg != cb.nf)
            return cmderror(cb, errmod.errstr(error.Ecmdargs));
        return ct;
    }

    return cmderror(cb, "unknown control message");
}

/// parsecmd on test memory instead of the kernel allocator.
fn testparse(mem: []align(@alignOf(Cmdbuf)) u8, p: []const u8) !*Cmdbuf {
    const nf = ncmdfield(p);
    try std.testing.expect(@sizeOf(Cmdbuf) + nf * @sizeOf([]u8) + p.len <= mem.len);
    return cmdfill(mem.ptr, p, nf);
}

fn expectFields(want: []const []const u8, p: []const u8) !void {
    var mem: [512]u8 align(@alignOf(Cmdbuf)) = undefined;
    const cb = try testparse(&mem, p);
    try std.testing.expectEqual(want.len, cb.nf);
    try std.testing.expectEqual(want.len, cb.f.len);
    for (want, cb.f) |w, g|
        try std.testing.expectEqualStrings(w, g);
}

test "ncmdfield" {
    const eq = std.testing.expectEqual;
    try eq(@as(usize, 0), ncmdfield(""));
    try eq(@as(usize, 0), ncmdfield(" \t\r\n"));
    try eq(@as(usize, 1), ncmdfield("a"));
    try eq(@as(usize, 3), ncmdfield("  add 1.2.3.4\t255.0.0.0\n"));
    // an estimate: quoting only ever joins fields
    try eq(@as(usize, 3), ncmdfield("name 'two words'"));
}

test "parsecmd" {
    try expectFields(&.{}, "");
    try expectFields(&.{}, "\n");
    try expectFields(&.{}, "  \t \n");
    try expectFields(&.{"hangup"}, "hangup");
    try expectFields(&.{"hangup"}, "hangup\n");
    try expectFields(&.{ "connect", "10.0.0.1!564" }, "connect 10.0.0.1!564\n");
    try expectFields(&.{ "a", "b", "c" }, " \ta  b\r\nc \n");
    // only one trailing newline is dumped, the rest is white space anyway
    try expectFields(&.{"x"}, "x\n\n");
}

test "parsecmd quoting" {
    try expectFields(&.{ "name", "two words" }, "name 'two words'\n");
    try expectFields(&.{ "say", "it's" }, "say 'it''s'");
    try expectFields(&.{ "a", "", "b" }, "a '' b");
    try expectFields(&.{"abc d"}, "a'b'c' d'");
    try expectFields(&.{ "x", "new\nline" }, "x 'new\nline'\n");
    // an unterminated quote runs to the end
    try expectFields(&.{ "a", "b c" }, "a 'b c");
    try expectFields(&.{"'"}, "''''");
}

test "parsecmd stops at NUL" {
    try expectFields(&.{ "a", "b" }, "a b\x00c d");
    try expectFields(&.{}, "\x00a");
}

test "parsecmd keeps the edited text" {
    var mem: [256]u8 align(@alignOf(Cmdbuf)) = undefined;
    const p = "bind 'a b' c\n";
    const cb = try testparse(&mem, p);
    try std.testing.expectEqual(p.len - 1, cb.buf.len);
    // fields point into buf
    for (cb.f) |a| {
        try std.testing.expect(@intFromPtr(a.ptr) >= @intFromPtr(cb.buf.ptr));
        try std.testing.expect(@intFromPtr(a.ptr) + a.len <= @intFromPtr(cb.buf.ptr) + cb.buf.len);
    }
}

test "tokenize limit" {
    var s = "a b c d".*;
    var args: [2][]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), tokenize(&s, &args));
    try std.testing.expectEqualStrings("a", args[0]);
    try std.testing.expectEqualStrings("b", args[1]);
}
