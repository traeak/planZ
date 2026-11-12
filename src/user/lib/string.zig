//! String helpers that the library and programs need.
//! tokenize and qtoken from libc/port/tokenize.c, the same port as the
//! kernel's in src/kernel/port/parse.zig (see its DIFF notes: the
//! string is a slice, edited in place, and the fields are slices);
//! cleanname from libc/port/cleanname.c, the same as the kernel's in
//! src/kernel/port/lib.zig; needsrcquote and the quoting of %q from
//! libc/port/needsrcquote.c and libc/fmt/fmtquote.c; Args from the
//! ARGBEGIN/ARGEND macros of libc.h.

const std = @import("std");

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
    while (t < buf.len and buf[t] != 0 and (quoting or !issep(buf[t]))) {
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
/// place.  A NUL ends the string.  Returns the number of fields.
pub fn tokenize(s: []u8, args: [][]u8) usize {
    var p: usize = 0;
    var nargs: usize = 0;
    while (nargs < args.len) : (nargs += 1) {
        while (p < s.len and s[p] != 0 and issep(s[p]))
            p += 1;
        if (p >= s.len or s[p] == 0)
            break;
        const r = qtoken(s, p);
        args[nargs] = s[p..r.end];
        p = r.next;
    }
    return nargs;
}

/// libc's atoi: a leading sign and decimal digits, after white space.
pub fn atoi(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t'))
        i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var n: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1)
        n = n *% 10 +% (s[i] - '0');
    return if (neg) -%n else n;
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

/// Whether rc needs c quoted.
/// from libc/port/needsrcquote.c
pub fn needsrcquote(c: u8) bool {
    if (c <= ' ')
        return true;
    return std.mem.findScalar(u8, "`^#*[]=|\\?${}()'<>&;", c) != null;
}

/// s as %q prints it: in single quotes, with quotes doubled, if it is
/// empty or has a character rc would need quoted; otherwise as it is.
/// DIFF: a function writing into buf (which must have room for
/// 2*s.len+2 bytes), not a format verb.
pub fn quote(buf: []u8, s: []const u8) []const u8 {
    var q = s.len == 0;
    for (s) |c| {
        if (needsrcquote(c)) q = true;
    }
    if (!q)
        return s;
    var n: usize = 0;
    buf[n] = '\'';
    n += 1;
    for (s) |c| {
        buf[n] = c;
        n += 1;
        if (c == '\'') {
            buf[n] = '\'';
            n += 1;
        }
    }
    buf[n] = '\'';
    n += 1;
    return buf[0..n];
}

/// The flags of a command line, as ARGBEGIN/ARGEND walk them: each
/// argument that starts with '-' (and is not just "-") holds flag
/// letters, "--" ends the flags, and so does the first other argument.
///
///     var args = libc.Args.init(argv);
///     while (args.next()) |c| switch (c) { 'n' => ..., else => usage() };
///     const files = args.rest();
pub const Args = struct {
    argv: []const []const u8,
    i: usize = 1,
    j: usize = 0,

    pub fn init(argv: []const []const u8) Args {
        return .{ .argv = argv };
    }

    /// The next flag letter, or null when the flags are done.
    pub fn next(a: *Args) ?u8 {
        while (a.i < a.argv.len) {
            const s = a.argv[a.i];
            if (a.j == 0) {
                if (s.len < 2 or s[0] != '-')
                    return null;
                if (std.mem.eql(u8, s, "--")) {
                    a.i += 1;
                    return null;
                }
                a.j = 1;
            }
            if (a.j < s.len) {
                a.j += 1;
                return s[a.j - 1];
            }
            a.i += 1;
            a.j = 0;
        }
        return null;
    }

    /// The value of the flag just returned (ARGF/EARGF): the rest of
    /// its argument, or the next argument.
    pub fn value(a: *Args) ?[]const u8 {
        if (a.i >= a.argv.len)
            return null;
        const s = a.argv[a.i];
        const j = a.j;
        a.i += 1;
        a.j = 0;
        if (j > 0 and j < s.len)
            return s[j..];
        if (a.i >= a.argv.len)
            return null;
        a.i += 1;
        return a.argv[a.i - 1];
    }

    /// The arguments after the flags.
    pub fn rest(a: *Args) []const []const u8 {
        if (a.j != 0) {
            a.i += 1;
            a.j = 0;
        }
        return a.argv[@min(a.i, a.argv.len)..];
    }
};
