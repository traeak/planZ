//! rc's globbing and pattern matching.
//! from cmd/rc/glob.c
//!
//! DIFF: strings are slices read through `at`, which gives 0 past the
//! end where the C reads the string's 0; globdir takes the pattern as a
//! slice where the C writes 0s into it for a while.

const std = @import("std");
const rc = @import("rc.zig");
const exec = @import("exec.zig");
const simple = @import("simple.zig");
const plan9 = @import("plan9.zig");

const Word = rc.Word;

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// Remove the GLOB marks from s (a GLOB GLOB becomes one GLOB); the
/// string shrinks to fit.
pub fn deglob(s: []u8) []u8 {
    const r0 = std.mem.indexOfScalar(u8, s, rc.GLOB) orelse return s;
    var w = r0;
    var r = r0 + 1;
    while (r < s.len) {
        if (s[r] == rc.GLOB) {
            r += 1;
            if (r == s.len) break; // the C copies the string's 0 here
        }
        s[w] = s[r];
        w += 1;
        r += 1;
    }
    return rc.erealloc(s, w);
}

fn globsort(left: ?*Word, right: ?*Word) void {
    var n: usize = 0;
    var a = left;
    while (a != right) : (a = a.?.next) n += 1;
    const list = rc.a.alloc([]u8, n) catch rc.panic("Can't malloc %d bytes", n);
    defer rc.a.free(list);
    a = left;
    n = 0;
    while (a != right) : (a = a.?.next) {
        list[n] = a.?.word;
        n += 1;
    }
    std.mem.sort([]u8, list, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    a = left;
    n = 0;
    while (a != right) : (a = a.?.next) {
        a.?.word = list[n];
        n += 1;
    }
}

/// Does the string s match the pattern p
/// . and .. are only matched by patterns starting with .
/// * matches any sequence of characters
/// ? matches any single character
/// [...] matches the enclosed list of characters
fn matchfn(s: []const u8, p: []const u8) bool {
    if (at(s, 0) == '.' and (at(s, 1) == 0 or at(s, 1) == '.' and at(s, 2) == 0) and at(p, 0) != '.')
        return false;
    return match(s, p, '/');
}

fn pappend(pdir: *[]u8, name: []const u8) void {
    const path = simple.makepath(pdir.*, name);
    rc.a.free(pdir.*);
    pdir.* = path;
}

fn globdir(list_: ?*Word, pattern_: []const u8, name_: []u8) ?*Word {
    var list = list_;
    var pattern = pattern_;
    var name = name_;

    // append slashes, Readdir() already filtered directories
    while (at(pattern, 0) == '/') {
        pappend(&name, "/");
        pattern = pattern[1..];
    }
    if (pattern.len == 0)
        return exec.Newword(name, list);

    // scan the pattern looking for a component with a metacharacter in it
    const g = std.mem.indexOfScalar(u8, pattern, rc.GLOB) orelse {
        // If we ran out of pattern, append the name if accessible
        pappend(&name, pattern);
        if (rc.libc.access(name, 0))
            return exec.Newword(name, list);
        rc.a.free(name);
        return list;
    };

    var glob = pattern[g..];
    if (std.mem.lastIndexOfScalar(u8, pattern[0..g], '/')) |slash| {
        pappend(&name, pattern[0..slash]);
        pattern = pattern[slash + 1 ..];
        glob = pattern[g - slash - 1 ..];
    }

    // read the directory and recur for any entry that matches
    const dir = plan9.Opendir(if (name.len > 0) name else ".") orelse {
        rc.a.free(name);
        return list;
    };
    const slash = std.mem.indexOfScalar(u8, glob, '/');
    while (plan9.Readdir(dir, slash != null)) |entry| {
        if (matchfn(entry, pattern))
            list = globdir(list, if (slash) |s| glob[s..] else "", simple.makepath(name, entry));
    }
    plan9.Closedir(dir);
    rc.a.free(name);
    return list;
}

/// Subsitute a word with its glob in place.
pub fn globword(w: *Word) void {
    if (std.mem.indexOfScalar(u8, w.word, rc.GLOB) == null)
        return;
    const right = w.next;
    const left = globdir(right, w.word, rc.estrdup(""));
    if (left == right) {
        w.word = deglob(w.word);
    } else {
        rc.a.free(w.word);
        globsort(left, right);
        w.next = left.?.next;
        w.word = exec.Freeword(left.?);
    }
}

/// The index of the next utf code in the string, not jumping past nuls
/// in broken utf codes!
fn nextutf(s: []const u8, p: usize) usize {
    const c = at(s, p);
    if (rc.onebyte(c))
        return p + 1;
    const n: usize = if (rc.twobyte(c)) 2 else if (rc.threebyte(c)) 3 else 4;
    var i: usize = 1;
    while (i < n) : (i += 1)
        if (!rc.xbyte(at(s, p + i))) break;
    return p + i;
}

/// Convert the utf code at p to a unicode value
fn unicode(s: []const u8, p: usize) i32 {
    const c: i32 = at(s, p);
    const c1: i32 = at(s, p + 1);
    const c2: i32 = at(s, p + 2);
    const c3: i32 = at(s, p + 3);

    if (rc.onebyte(c))
        return c & 0xFF;
    if (rc.twobyte(c)) {
        if (rc.xbyte(c1))
            return ((c & 0x1F) << 6) | (c1 & 0x3F);
    } else if (rc.threebyte(c)) {
        if (rc.xbyte(c1) and rc.xbyte(c2))
            return ((c & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
    } else if (rc.fourbyte(c)) {
        if (rc.xbyte(c1) and rc.xbyte(c2) and rc.xbyte(c3))
            return ((c & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
    }
    return -1;
}

/// Do p and q point at equal utf codes
fn equtf(p: []const u8, pi: usize, q: []const u8, qi: usize) bool {
    if (at(p, pi) != at(q, qi))
        return false;
    return unicode(p, pi) == unicode(q, qi);
}

pub fn match(s: []const u8, p: []const u8, stop: u8) bool {
    return match1(s, 0, p, 0, stop);
}

fn match1(s: []const u8, si_: usize, p: []const u8, pi_: usize, stop: u8) bool {
    var si = si_;
    var pi = pi_;
    while (at(p, pi) != stop and at(p, pi) != 0) : ({
        si = nextutf(s, si);
        pi = nextutf(p, pi);
    }) {
        if (at(p, pi) != rc.GLOB) {
            if (!equtf(p, pi, s, si)) return false;
        } else {
            pi += 1;
            switch (at(p, pi)) {
                rc.GLOB => {
                    if (at(s, si) != rc.GLOB)
                        return false;
                },
                '*' => {
                    while (true) {
                        if (match1(s, si, p, nextutf(p, pi), stop)) return true;
                        if (at(s, si) == 0)
                            break;
                        si = nextutf(s, si);
                    }
                    return false;
                },
                '?' => {
                    if (at(s, si) == 0)
                        return false;
                },
                '[' => {
                    if (at(s, si) == 0)
                        return false;
                    const c = unicode(s, si);
                    pi += 1;
                    const compl = at(p, pi) == '~';
                    if (compl)
                        pi += 1;
                    var hit = false;
                    while (at(p, pi) != ']') {
                        if (at(p, pi) == 0)
                            return false; // syntax error
                        var lo = unicode(p, pi);
                        var hi: i32 = undefined;
                        pi = nextutf(p, pi);
                        if (at(p, pi) != '-')
                            hi = lo
                        else {
                            pi += 1;
                            if (at(p, pi) == 0)
                                return false; // syntax error
                            hi = unicode(p, pi);
                            pi = nextutf(p, pi);
                            if (hi < lo) std.mem.swap(i32, &lo, &hi);
                        }
                        if (lo <= c and c <= hi)
                            hit = true;
                    }
                    if (compl)
                        hit = !hit;
                    if (!hit)
                        return false;
                },
                else => {},
            }
        }
    }
    return at(s, si) == 0;
}
