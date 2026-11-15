//! A console's text: what was written to it, what is being typed, and
//! which part of it is on the screen.  The line discipline of rio's
//! text windows, without rio's mouse and its selection (see DIFF).
//! From /sys/src/cmd/rio/wind.c (9front 11952): winsert, wdelete,
//! wbswidth, wbacknl, wkeyctl, and winctl's cons write (WCwrite) and
//! read (WCread); cvttorunes from util.c.
//!
//! DIFF:
//!   - No frame (libframe).  The caller repaints from org; lines are
//!     laid out here (Layout), wrapped at the width, a tab reaching to
//!     the next multiple of maxtab.  org is always the start of a
//!     screen line, and scrolling moves by screen lines: show() puts a
//!     position that is off the screen on the last line (going
//!     forward) or the first (going back), where wshow puts it 4/5 of
//!     the way down; PgDn and Down stop when the end of the text is on
//!     the last line.  Looking back for the start of a line stops after
//!     MaxBack runes, as wbacknl calls 128 runes a line.
//!   - No selection of rio's kind: q1 is q0, so typing cuts and snarfs
//!     nothing, and ^F and Insert (file name completion) do nothing.
//!     In its place, the selection of an X11 terminal: s0 to s1 is
//!     text marked with the mouse, shown by the caller and copied by
//!     it; it is apart from where typing goes, moves with the text
//!     when text before it comes or goes, and is dropped when the
//!     marked text itself changes.  charAt, wordAt and lineAt find
//!     what the mouse points at; paste() is wpaste.
//!   - Always scrolling (rio's -scroll): a write never waits.
//!   - PgUp and PgDn do the same with Shift held (Linux's keys).
//!   - Holding is drawn by the caller, which also sends the interrupt
//!     that key() asks for.
//!   - Kscrolloneup/down move one line (rio: mousescrollsize);
//!     scroll() is for the caller's mouse wheel.
//!   - holding is a bool: holdon and Esc hold, holdoff and Esc or
//!     Delete let go, where rio counts holdons.  What was typed in raw
//!     mode is typed again when it ends, a Delete among it with no
//!     interrupt.
//!
//! Not part of 9front: vtfs.

const std = @import("std");
const libc = @import("libc");

pub const Rune = libc.Rune;
const UTFmax = libc.UTFmax;

// keyboard.h
const KF = 0xF000;
const Spec = 0xF800;
pub const Kview = Spec | 0x00;
pub const Khome = KF | 0x0D;
pub const Kup = KF | 0x0E;
pub const Kdown = Kview;
pub const Kpgup = KF | 0x0F;
pub const Kleft = KF | 0x11;
pub const Kright = KF | 0x12;
pub const Kpgdown = KF | 0x13;
pub const Kins = KF | 0x14;
pub const Kalt = KF | 0x15;
pub const Kshift = KF | 0x16;
pub const Kctl = KF | 0x17;
pub const Kend = KF | 0x18;
pub const Kscroll = KF | 0x19;
pub const Kscrolloneup = KF | 0x20;
pub const Kscrollonedown = KF | 0x21;
pub const Ksoh = 0x01;
pub const Kstx = 0x02;
pub const Keof = 0x04;
pub const Kenq = 0x05;
pub const Kack = 0x06;
pub const Kbs = 0x08;
pub const Knack = 0x15;
pub const Ketb = 0x17;
pub const Kdel = 0x7f;
pub const Kesc = 0x1b;
pub const Kcaps = Spec | 0x64;
pub const Knum = Spec | 0x65;
pub const Kaltgr = Spec | 0x67;

const HiWater = 640000; // max size of history
const LoWater = 400000; // min size of history after max'ed

/// How far back to look for the start of a line.
const MaxBack = 4096;

/// How the text is cut into screen lines.
pub const Layout = struct {
    wid: i32, // of a line, in pixels
    maxlines: usize,
    maxtab: i32, // pixels
    ctx: *const anyopaque,
    width: *const fn (ctx: *const anyopaque, r: Rune) i32,

    /// The width of r drawn at x.
    pub fn runewidth(l: *const Layout, r: Rune, x: i32) i32 {
        if (r == '\t')
            return l.maxtab - @mod(x, l.maxtab);
        return l.width(l.ctx, r);
    }
};

pub const Action = enum { none, interrupt };

pub const Text = struct {
    a: std.mem.Allocator,
    lay: Layout,
    r: std.ArrayList(Rune) = .empty,
    raw: std.ArrayList(Rune) = .empty, // typed in raw mode, not shown
    q0: usize = 0, // where typing goes
    s0: usize = 0, // marked with the mouse: s0 to s1
    s1: usize = 0,
    qh: usize = 0, // the output point: before it, written or read
    org: usize = 0, // the first rune on the screen
    rawing: u32 = 0,
    holding: bool = false,
    part: [UTFmax]u8 = undefined, // a rune a read cut short
    npart: usize = 0,

    pub fn deinit(t: *Text) void {
        t.r.deinit(t.a);
        t.raw.deinit(t.a);
    }

    fn nr(t: *const Text) usize {
        return t.r.items.len;
    }

    // ---- layout

    /// The start of the screen line after the one starting at p, or
    /// null if that line runs to the end of the text.
    pub fn nextLine(t: *const Text, p: usize) ?usize {
        var x: i32 = 0;
        var q = p;
        while (q < t.nr()) : (q += 1) {
            const c = t.r.items[q];
            if (c == '\n')
                return q + 1;
            const w = t.lay.runewidth(c, x);
            if (x + w > t.lay.wid and q > p)
                return q;
            x += w;
        }
        return null;
    }

    /// The start of the screen line that q is on.
    pub fn lineStart(t: *const Text, q: usize) usize {
        var s = q;
        while (s > 0 and t.r.items[s - 1] != '\n' and q - s < MaxBack)
            s -= 1;
        while (true) {
            const n = t.nextLine(s) orelse return s;
            if (n > q)
                return s;
            s = n;
        }
    }

    /// n lines on from the line starting at s, or the last line.
    pub fn linesFrom(t: *const Text, s: usize, n: usize) usize {
        var p = s;
        for (0..n) |_|
            p = t.nextLine(p) orelse break;
        return p;
    }

    /// n lines back from the line starting at s, or the first.
    pub fn linesBack(t: *const Text, s: usize, n: usize) usize {
        var p = s;
        for (0..n) |_| {
            if (p == 0)
                break;
            p = t.lineStart(p - 1);
        }
        return p;
    }

    /// Whether position q is on the screen.
    pub fn visible(t: *const Text, q: usize) bool {
        if (q < t.org)
            return false;
        var p = t.org;
        for (0..t.lay.maxlines) |_| {
            const n = t.nextLine(p) orelse return true;
            if (q < n)
                return true;
            p = n;
        }
        return false;
    }

    /// The origin that puts the end of the text on the last line.
    pub fn bottom(t: *const Text) usize {
        return t.linesBack(t.lineStart(t.nr()), t.lay.maxlines -| 1);
    }

    /// Scroll so that q is on the screen (wshow).
    pub fn show(t: *Text, q: usize) void {
        if (t.visible(q))
            return;
        if (q < t.org)
            t.org = t.lineStart(q)
        else
            t.org = t.linesBack(t.lineStart(q), t.lay.maxlines -| 1);
    }

    /// Lay out again after the width or the font changed.
    pub fn relayout(t: *Text, lay: Layout) void {
        t.lay = lay;
        t.org = t.lineStart(t.org);
        t.show(t.q0);
    }

    // ---- editing

    /// Insert rs at q0 and return where it went (winsert).
    pub fn insert(t: *Text, rs: []const Rune, q0_: usize) std.mem.Allocator.Error!usize {
        var q0 = q0_;
        const n = rs.len;
        if (n == 0)
            return q0;
        if (t.nr() + n > HiWater and q0 >= t.org and q0 >= t.qh) {
            const m = @min(HiWater - LoWater, @min(t.org, t.qh));
            t.org -= m;
            t.qh -= m;
            t.q0 -|= m;
            t.r.replaceRangeAssumeCapacity(0, m, &.{});
            q0 -= m;
            if (t.s0 < m) {
                t.s0 = 0;
                t.s1 = 0;
            } else {
                t.s0 -= m;
                t.s1 -= m;
            }
        }
        try t.r.insertSlice(t.a, q0, rs);
        if (t.s0 < t.s1) {
            if (q0 <= t.s0) {
                t.s0 += n;
                t.s1 += n;
            } else if (q0 < t.s1) {
                t.s0 = 0;
                t.s1 = 0;
            }
        }
        // if output touches, advance selection, not qh; works best for keyboard and output
        if (q0 <= t.q0)
            t.q0 += n;
        if (q0 < t.qh)
            t.qh += n;
        if (q0 < t.org)
            t.org += n;
        return q0;
    }

    /// Delete the runes from q0 to q1 (wdelete).
    pub fn delete(t: *Text, q0: usize, q1: usize) void {
        const n = q1 - q0;
        if (n == 0)
            return;
        t.r.replaceRangeAssumeCapacity(q0, n, &.{});
        if (t.s0 < t.s1) {
            if (q1 <= t.s0) {
                t.s0 -= n;
                t.s1 -= n;
            } else if (q0 < t.s1) {
                t.s0 = 0;
                t.s1 = 0;
            }
        }
        if (q0 < t.q0)
            t.q0 -= @min(n, t.q0 - q0);
        if (q1 < t.qh)
            t.qh -= n
        else if (q0 < t.qh)
            t.qh = q0;
        if (q1 <= t.org)
            t.org -= n
        else if (q0 < t.org)
            t.org = q0;
    }

    /// How much ^H, ^U or ^W erases before q0 (wbswidth).
    fn bswidth(t: *const Text, c: Rune) usize {
        // there is known to be at least one character to erase
        if (c == Kbs) // ^H: erase character
            return 1;
        var q = t.q0;
        var stop: usize = 0;
        if (q > t.qh)
            stop = t.qh;
        var skipping = true;
        while (q > stop) {
            const r = t.r.items[q - 1];
            if (r == '\n') { // eat at most one more character
                if (q == t.q0) // eat the newline
                    q -= 1;
                break;
            }
            if (c == Ketb) {
                const eq = isalnum(r);
                if (eq and skipping) // found one; stop skipping
                    skipping = false
                else if (!eq and !skipping)
                    break;
            }
            q -= 1;
        }
        return t.q0 - q;
    }

    /// Move the screen n lines (one at least) down the text, or up;
    /// not past the bottom, where the last line is the screen's last.
    pub fn scroll(t: *Text, down: bool, n: usize) void {
        if (down) {
            const b = t.bottom();
            if (t.org < b)
                t.org = @min(t.linesFrom(t.org, @max(n, 1)), b);
        } else t.org = t.linesBack(t.org, @max(n, 1));
    }

    /// A typed key (wkeyctl).  shift: Shift is held.
    pub fn key(t: *Text, r: Rune, shift: bool) std.mem.Allocator.Error!Action {
        switch (r) {
            0, Kcaps, Knum, Kshift, Kalt, Kctl, Kaltgr => return .none,
            else => {},
        }

        // navigation keys
        switch (r) {
            Kdown, Kscrollonedown, Kpgdown => {
                const n = switch (r) {
                    Kdown => if (shift) 1 else t.lay.maxlines / 3,
                    Kscrollonedown => 1,
                    else => 2 * t.lay.maxlines / 3,
                };
                t.scroll(true, n);
                return .none;
            },
            Kup, Kscrolloneup, Kpgup => {
                const n = switch (r) {
                    Kup => if (shift) 1 else t.lay.maxlines / 3,
                    Kscrolloneup => 1,
                    else => 2 * t.lay.maxlines / 3,
                };
                t.scroll(false, n);
                return .none;
            },
            Kleft => {
                if (t.q0 > 0) {
                    t.q0 -= 1;
                    t.show(t.q0);
                }
                return .none;
            },
            Kright => {
                if (t.q0 < t.nr()) {
                    t.q0 += 1;
                    t.show(t.q0);
                }
                return .none;
            },
            Khome => {
                t.show(0);
                return .none;
            },
            Kend => {
                t.show(t.nr());
                return .none;
            },
            Kscroll => {
                t.show(t.nr());
                return .none;
            },
            Ksoh => { // ^A: beginning of line
                if (t.q0 == 0 or t.q0 == t.qh or t.r.items[t.q0 - 1] == '\n')
                    return .none;
                t.q0 -= t.bswidth(Knack);
                t.show(t.q0);
                return .none;
            },
            Kenq => { // ^E: end of line
                var q = t.q0;
                while (q < t.nr() and t.r.items[q] != '\n')
                    q += 1;
                t.q0 = q;
                t.show(t.q0);
                return .none;
            },
            Kstx => { // ^B: output point
                t.q0 = t.qh;
                t.show(t.q0);
                return .none;
            },
            else => {},
        }
        if (t.rawing > 0 and t.q0 == t.nr()) {
            try t.raw.append(t.a, r);
            return .none;
        }
        if (r == Kesc or (t.holding and r == Kdel)) { // toggle hold
            t.holding = !t.holding;
            if (r == Kesc)
                return .none;
        }
        switch (r) {
            Kdel => { // send interrupt
                t.qh = t.nr();
                t.show(t.qh);
                return .interrupt;
            },
            Kack, Kins => return .none, // file name completion
            Kbs, Knack, Ketb => { // erase character, line, word
                if (t.q0 == 0 or t.q0 == t.qh)
                    return .none;
                var nb = t.bswidth(r);
                const q1 = t.q0;
                var q0 = q1 - nb;
                if (q0 < t.org) {
                    q0 = t.org;
                    nb = q1 - q0;
                }
                if (nb > 0) {
                    t.delete(q0, q0 + nb);
                    t.q0 = q0;
                }
                return .none;
            },
            else => {},
        }
        // otherwise ordinary character; just insert
        const q0 = try t.insert(&.{r}, t.q0);
        t.show(q0 + 1);
        return .none;
    }

    // ---- consctl

    /// A message written to consctl (xfidwrite's Qconsctl); false if
    /// it is none of rawon, rawoff, holdon and holdoff.  Raw mode is
    /// counted; when it ends, what was typed raw is typed again.
    pub fn ctl(t: *Text, m: []const u8) std.mem.Allocator.Error!bool {
        if (std.mem.startsWith(u8, m, "holdon")) {
            t.holding = true;
        } else if (std.mem.startsWith(u8, m, "holdoff")) {
            t.holding = false;
        } else if (std.mem.startsWith(u8, m, "rawon")) {
            t.holding = false;
            t.rawing += 1;
        } else if (std.mem.startsWith(u8, m, "rawoff")) {
            if (t.rawing > 0) {
                t.rawing -= 1;
                if (t.rawing == 0)
                    try t.unraw();
            }
        } else return false;
        return true;
    }

    /// consctl was closed: raw mode and holding end.
    pub fn ctlclose(t: *Text) std.mem.Allocator.Error!void {
        t.holding = false;
        if (t.rawing > 0) {
            t.rawing = 0;
            try t.unraw();
        }
    }

    fn unraw(t: *Text) std.mem.Allocator.Error!void {
        while (t.raw.items.len > 0)
            _ = try t.key(t.raw.orderedRemove(0), false);
    }

    // ---- cons

    /// Written to cons: backspaces in rs erase what comes before them,
    /// the output before qh too; the rest goes in at qh.  rs is used
    /// as the work space.
    pub fn write(t: *Text, rs: []Rune) std.mem.Allocator.Error!void {
        var n = rs.len;
        if (std.mem.indexOfScalar(Rune, rs, Kbs)) |first| {
            var up = first;
            var initial: usize = 0;
            for (rs[first..]) |c| {
                if (c == Kbs) {
                    if (up == 0)
                        initial += 1
                    else
                        up -= 1;
                } else {
                    rs[up] = c;
                    up += 1;
                }
            }
            if (initial > 0) {
                initial = @min(initial, t.qh);
                const qh = t.qh - initial;
                t.delete(qh, qh + initial);
                t.qh = qh;
            }
            n = up;
        }
        t.qh = try t.insert(rs[0..n], t.qh) + n;
        t.show(t.qh);
    }

    /// Whether a read of cons can be answered now.
    pub fn readable(t: *const Text) bool {
        if (t.holding)
            return false;
        if (t.npart > 0 or (t.rawing > 0 and t.raw.items.len > 0))
            return true;
        for (t.r.items[t.qh..]) |c|
            if (c == '\n' or c == Keof) return true;
        return false;
    }

    /// A read of cons: a typed line, or in raw mode what was typed.
    /// A ^D ends what is read and is not returned.
    pub fn read(t: *Text, buf: []u8) usize {
        const nb = buf.len;
        // the rest of a rune the last read cut short
        var i = @min(t.npart, nb);
        @memcpy(buf[0..i], t.part[0..i]);
        std.mem.copyForwards(u8, t.part[0 .. t.npart - i], t.part[i..t.npart]);
        t.npart -= i;
        if (t.npart > 0)
            return i;
        while (i < nb and (t.qh < t.nr() or t.raw.items.len > 0)) {
            var c: Rune = undefined;
            if (t.qh == t.nr()) {
                c = t.raw.orderedRemove(0);
            } else {
                c = t.r.items[t.qh];
                t.qh += 1;
            }
            var tmp: [UTFmax]u8 = undefined;
            const wid = libc.runetochar(&tmp, c);
            const fit = @min(wid, nb - i);
            @memcpy(buf[i..][0..fit], tmp[0..fit]);
            if (fit < wid) {
                @memcpy(t.part[0 .. wid - fit], tmp[fit..wid]);
                t.npart = wid - fit;
            }
            i += fit;
            if (t.rawing == 0 and (c == '\n' or c == Keof)) {
                if (c == Keof)
                    i -= 1;
                break;
            }
        }
        if (i == nb and t.qh < t.nr() and t.r.items[t.qh] == Keof)
            t.qh += 1;
        return i;
    }

    /// The whole text as UTF-8, for the text file.
    pub fn bytes(t: *const Text, a: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return utf(a, t.r.items);
    }

    fn utf(a: std.mem.Allocator, rs: []const Rune) std.mem.Allocator.Error![]u8 {
        var n: usize = 0;
        for (rs) |c| n += libc.runelen(c);
        const s = try a.alloc(u8, n);
        var i: usize = 0;
        for (rs) |c| i += libc.runetochar(s[i..], c);
        return s;
    }

    // ---- the mouse's selection

    /// The position the mouse points at: on screen line `row` (from
    /// 0), x pixels from the left edge of the text.  A point in the
    /// right half of a character is the position after it; past the
    /// end of a line, the line's end; below the text, the text's end.
    pub fn charAt(t: *const Text, row: usize, x: i32) usize {
        var p = t.org;
        for (0..row) |_|
            p = t.nextLine(p) orelse return t.nr();
        const e = t.nextLine(p) orelse t.nr();
        var xx: i32 = 0;
        var q = p;
        while (q < e) : (q += 1) {
            const c = t.r.items[q];
            if (c == '\n')
                return q;
            const w = t.lay.runewidth(c, xx);
            if (2 * (x - xx) < w)
                return q;
            xx += w;
        }
        return q;
    }

    fn isspace(c: Rune) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    /// The word at q, for a double click: the run of characters that
    /// are not white space (a file name, a command's argument).
    /// Nothing, at white space or the end.
    pub fn wordAt(t: *const Text, q: usize) [2]usize {
        const r = t.r.items;
        if (q >= r.len or isspace(r[q]))
            return .{ q, q };
        var a = q;
        var b = q;
        while (a > 0 and !isspace(r[a - 1])) a -= 1;
        while (b < r.len and !isspace(r[b])) b += 1;
        return .{ a, b };
    }

    /// The line at q, for a triple click: from after the newline
    /// before q to the next one, which is left out.
    pub fn lineAt(t: *const Text, q_: usize) [2]usize {
        const r = t.r.items;
        const q = @min(q_, r.len);
        var a = q;
        var b = q;
        while (a > 0 and r[a - 1] != '\n') a -= 1;
        while (b < r.len and r[b] != '\n') b += 1;
        return .{ a, b };
    }

    /// Mark the text from a to b.
    pub fn select(t: *Text, a: usize, b: usize) void {
        t.s0 = @min(@min(a, b), t.nr());
        t.s1 = @min(@max(a, b), t.nr());
    }

    /// The marked text as UTF-8.
    pub fn selection(t: *const Text, a: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return utf(a, t.r.items[t.s0..t.s1]);
    }

    /// Put rs where typing goes, as if typed but with no key's
    /// meaning: a Delete in it interrupts nothing (wpaste).
    pub fn paste(t: *Text, rs: []const Rune) std.mem.Allocator.Error!void {
        if (rs.len == 0)
            return;
        if (t.rawing > 0 and t.q0 == t.nr()) {
            try t.raw.appendSlice(t.a, rs);
            return;
        }
        _ = try t.insert(rs, t.q0);
        t.show(t.q0);
    }
};

/// UTF-8 written to cons, as runes; what ends in the middle of a rune
/// is kept for the next write.
pub const Partial = struct {
    b: [UTFmax]u8 = undefined,
    n: usize = 0,

    /// Decode p's bytes and data into a new slice of runes, NULs left
    /// out (cvttorunes).
    pub fn runes(p: *Partial, a: std.mem.Allocator, data: []const u8) std.mem.Allocator.Error![]Rune {
        const in = try a.alloc(u8, p.n + data.len);
        defer a.free(in);
        @memcpy(in[0..p.n], p.b[0..p.n]);
        @memcpy(in[p.n..], data);
        p.n = 0;
        const out = try a.alloc(Rune, in.len);
        var nr: usize = 0;
        var j: usize = 0;
        while (j < in.len) {
            if (!libc.fullrune(in[j..])) {
                p.n = in.len - j;
                @memcpy(p.b[0..p.n], in[j..]);
                break;
            }
            var c: Rune = undefined;
            var w: usize = 1;
            if (in[j] < libc.Runeself) {
                c = in[j];
            } else {
                const cr = libc.chartorune(in[j..]);
                c = cr.r;
                w = cr.n;
            }
            j += w;
            if (c != 0) {
                out[nr] = c;
                nr += 1;
            }
        }
        return a.realloc(out, nr);
    }
};

/// rio's isalnum, for ^W.
fn isalnum(c: Rune) bool {
    // Hard to get absolutely right.  Use what we know about ASCII
    // and assume anything above the Latin control characters is
    // potentially an alphanumeric.
    if (c <= ' ')
        return false;
    if (0x7F <= c and c <= 0xA0)
        return false;
    if (std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~", @truncate(c)) != null and c < 0x80)
        return false;
    return true;
}

// ---- host tests: a layout of character cells, 10 wide and 4 high

fn cell(_: *const anyopaque, _: Rune) i32 {
    return 1;
}

const test_lay: Layout = .{ .wid = 10, .maxlines = 4, .maxtab = 4, .ctx = &{}, .width = cell };

fn testText() Text {
    return .{ .a = std.testing.allocator, .lay = test_lay };
}

fn put(t: *Text, s: []const u8) !void {
    var p: Partial = .{};
    const rs = try p.runes(std.testing.allocator, s);
    defer std.testing.allocator.free(rs);
    try t.write(rs);
}

fn typ(t: *Text, s: []const u8) !void {
    for (s) |c| _ = try t.key(c, false);
}

fn expectText(t: *const Text, want: []const u8) !void {
    const s = try t.bytes(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(want, s);
}

fn readAll(t: *Text, buf: []u8) []u8 {
    return buf[0..t.read(buf)];
}

test "lines wrap at the width, at newlines and at tabs" {
    var t = testText();
    defer t.deinit();
    try put(&t, "0123456789abc\nxy\n\tz\t\t\tw");
    try std.testing.expectEqual(10, t.nextLine(0).?); // wrapped
    try std.testing.expectEqual(14, t.nextLine(10).?); // "abc\n"
    try std.testing.expectEqual(17, t.nextLine(14).?); // "xy\n"
    // "\tz\t\t" reaches 12: the third tab goes to the next line
    try std.testing.expectEqual(20, t.nextLine(17).?);
    try std.testing.expectEqual(null, t.nextLine(20));
    try std.testing.expectEqual(10, t.lineStart(12));
    try std.testing.expectEqual(10, t.lineStart(10));
    try std.testing.expectEqual(0, t.lineStart(9));
    try std.testing.expectEqual(20, t.lineStart(t.r.items.len));
}

test "a newline at the end starts an empty last line" {
    var t = testText();
    defer t.deinit();
    try put(&t, "a\nb\nc\nd\n");
    // five lines in four: the empty one after d is shown, a is not
    try std.testing.expectEqual(2, t.org);
    try std.testing.expect(t.visible(8));
    try std.testing.expect(!t.visible(0));
    try std.testing.expectEqual(8, t.lineStart(8));
}

test "output scrolls; PgUp and PgDn move by lines and stop at the end" {
    var t = testText();
    defer t.deinit();
    for (0..10) |i| {
        var b: [8]u8 = undefined;
        try put(&t, std.fmt.bufPrint(&b, "l{d}\n", .{i}) catch unreachable);
    }
    // l7 l8 l9 and the empty line
    try std.testing.expectEqual(21, t.org);
    try std.testing.expectEqual(t.bottom(), t.org);
    _ = try t.key(Kpgup, false); // 2*4/3 = 2 lines
    try std.testing.expectEqual(15, t.org);
    _ = try t.key(Kpgup, true);
    try std.testing.expectEqual(9, t.org);
    _ = try t.key(Kup, true); // one line
    try std.testing.expectEqual(6, t.org);
    _ = try t.key(Kpgdown, false);
    try std.testing.expectEqual(12, t.org);
    _ = try t.key(Kpgdown, false);
    _ = try t.key(Kpgdown, false);
    try std.testing.expectEqual(21, t.org); // not past the end
    _ = try t.key(Khome, false);
    try std.testing.expectEqual(0, t.org);
    try put(&t, "x"); // output brings the end back
    try std.testing.expect(t.visible(t.r.items.len));
}

test "a typed line is read with its newline; output goes before typing" {
    var t = testText();
    defer t.deinit();
    try put(&t, "% ");
    try typ(&t, "ls");
    try std.testing.expect(!t.readable());
    try put(&t, "out\n");
    try expectText(&t, "% out\nls");
    try typ(&t, "\n");
    try std.testing.expect(t.readable());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ls\n", readAll(&t, &buf));
    try std.testing.expect(!t.readable());
    try std.testing.expectEqual(t.r.items.len, t.qh);
}

test "erase character, word and line stop at the output point" {
    var t = testText();
    defer t.deinit();
    try put(&t, "% ");
    try typ(&t, "echo foo.bar baz");
    try typ(&t, "\x08");
    try expectText(&t, "% echo foo.bar ba");
    try typ(&t, "\x17"); // ^W: the word
    try expectText(&t, "% echo foo.bar ");
    try typ(&t, "\x17"); // white space, then the word
    try expectText(&t, "% echo foo.");
    try typ(&t, "\x15"); // ^U: the line
    try expectText(&t, "% ");
    try typ(&t, "\x08\x15"); // nothing typed: nothing erased
    try expectText(&t, "% ");
}

test "^D ends a read and is not returned" {
    var t = testText();
    defer t.deinit();
    try typ(&t, "ab\x04");
    try std.testing.expect(t.readable());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ab", readAll(&t, &buf));
    try typ(&t, "\x04");
    try std.testing.expectEqualStrings("", readAll(&t, &buf));
    try std.testing.expect(!t.readable());
}

test "a read cut in the middle of a rune keeps the rest" {
    var t = testText();
    defer t.deinit();
    for ([_]Rune{ 'a', 0x263A, '\n' }) |c| _ = try t.key(c, false);
    var buf: [2]u8 = undefined;
    try std.testing.expectEqualStrings("a\xe2", readAll(&t, &buf));
    try std.testing.expect(t.readable());
    try std.testing.expectEqualStrings("\x98\xba", readAll(&t, &buf));
    try std.testing.expectEqualStrings("\n", readAll(&t, &buf));
}

test "raw mode: keys are read as typed and not shown" {
    var t = testText();
    defer t.deinit();
    t.rawing = 1;
    try typ(&t, "q");
    try expectText(&t, "");
    try std.testing.expect(t.readable());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("q", readAll(&t, &buf));
    t.rawing = 0;
}

test "Delete drops the typing and asks for an interrupt; Esc holds" {
    var t = testText();
    defer t.deinit();
    try typ(&t, "abc");
    try std.testing.expectEqual(Action.interrupt, try t.key(Kdel, false));
    try typ(&t, "\n");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\n", readAll(&t, &buf));
    _ = try t.key(Kesc, false);
    try typ(&t, "x\n");
    try std.testing.expect(!t.readable());
    try std.testing.expectEqual(Action.interrupt, try t.key(Kdel, false)); // and lets go
    try std.testing.expect(!t.holding);
}

test "what was typed raw is typed again when raw mode ends" {
    var t = testText();
    defer t.deinit();
    try std.testing.expect(try t.ctl("rawon"));
    try std.testing.expect(try t.ctl("rawon"));
    try typ(&t, "ab");
    try std.testing.expect(try t.ctl("rawoff"));
    try expectText(&t, "");
    try std.testing.expect(try t.ctl("rawoff"));
    try expectText(&t, "ab");
    try std.testing.expect(!try t.ctl("bogus"));
    _ = try t.ctl("rawon");
    try typ(&t, "c");
    try t.ctlclose();
    try expectText(&t, "abc");
    try std.testing.expectEqual(0, t.rawing);
}

test "backspaces written erase the output before them" {
    var t = testText();
    defer t.deinit();
    try put(&t, "abc");
    try typ(&t, "t");
    try put(&t, "\x08\x08x\x08y");
    try expectText(&t, "ayt");
    try std.testing.expectEqual(2, t.qh);
}

test "partial UTF-8 is kept between writes; NULs are dropped" {
    var p: Partial = .{};
    const a = std.testing.allocator;
    const r1 = try p.runes(a, "a\x00\xe2\x98");
    defer a.free(r1);
    try std.testing.expectEqualSlices(Rune, &.{'a'}, r1);
    const r2 = try p.runes(a, "\xbab");
    defer a.free(r2);
    try std.testing.expectEqualSlices(Rune, &.{ 0x263A, 'b' }, r2);
}

test "cursor keys and ^A ^E ^B move where typing goes" {
    var t = testText();
    defer t.deinit();
    try put(&t, "% ");
    try typ(&t, "ac");
    _ = try t.key(Kleft, false);
    try typ(&t, "b");
    try expectText(&t, "% abc");
    _ = try t.key(Ksoh, false);
    try std.testing.expectEqual(2, t.q0);
    _ = try t.key(Kenq, false);
    try std.testing.expectEqual(5, t.q0);
    _ = try t.key(Kstx, false);
    try std.testing.expectEqual(2, t.q0);
}

test "history is cut when it passes HiWater" {
    var t = testText();
    defer t.deinit();
    const a = std.testing.allocator;
    const big = try a.alloc(Rune, HiWater - 1);
    defer a.free(big);
    @memset(big, 'x');
    try t.write(big);
    try put(&t, "yy");
    try std.testing.expectEqual(HiWater + 1 - (HiWater - LoWater), t.r.items.len);
    try std.testing.expectEqual(t.r.items.len, t.qh);
}

test "the wheel's scroll stops at the top and at the bottom" {
    var t = testText();
    defer t.deinit();
    for (0..20) |_| try put(&t, "l\n");
    const b = t.bottom();
    try std.testing.expectEqual(b, t.org);
    t.scroll(true, 3); // at the bottom already
    try std.testing.expectEqual(b, t.org);
    t.scroll(false, 3);
    try std.testing.expectEqual(b - 6, t.org);
    t.scroll(true, 0); // one line at least
    try std.testing.expectEqual(b - 4, t.org);
    t.scroll(true, 3);
    try std.testing.expectEqual(b, t.org);
    t.scroll(false, 100);
    try std.testing.expectEqual(0, t.org);
}

test "the mouse points between characters, at a line's end, at the text's end" {
    var t = testText();
    defer t.deinit();
    try put(&t, "abc\ndefghijklmnop\n\tx");
    // row 0: abc; row 1: defghijklm; row 2: nop; row 3: tab, x
    try std.testing.expectEqual(0, t.charAt(0, 0));
    try std.testing.expectEqual(1, t.charAt(0, 1));
    try std.testing.expectEqual(3, t.charAt(0, 9)); // past the end: the newline
    try std.testing.expectEqual(4, t.charAt(1, 0));
    try std.testing.expectEqual(14, t.charAt(1, 50)); // a wrapped line: the next line's start
    try std.testing.expectEqual(14, t.charAt(2, 0));
    try std.testing.expectEqual(17, t.charAt(2, 7));
    try std.testing.expectEqual(18, t.charAt(3, 1)); // in the tab's left half
    try std.testing.expectEqual(19, t.charAt(3, 3)); // in its right half
    try std.testing.expectEqual(20, t.charAt(3, 9));
    try std.testing.expectEqual(20, t.charAt(7, 0)); // below the text
}

test "a double click takes a word, a triple click a line" {
    var t = testText();
    defer t.deinit();
    try put(&t, "ls /bin/rc x\nnext");
    try std.testing.expectEqual([2]usize{ 3, 10 }, t.wordAt(5));
    try std.testing.expectEqual([2]usize{ 0, 2 }, t.wordAt(0));
    try std.testing.expectEqual([2]usize{ 2, 2 }, t.wordAt(2)); // white space
    try std.testing.expectEqual([2]usize{ 13, 17 }, t.wordAt(15));
    try std.testing.expectEqual([2]usize{ 17, 17 }, t.wordAt(17)); // the end
    try std.testing.expectEqual([2]usize{ 0, 12 }, t.lineAt(5));
    try std.testing.expectEqual([2]usize{ 13, 17 }, t.lineAt(17));
    t.select(10, 3);
    const s = try t.selection(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("/bin/rc", s);
}

test "the marked text moves with the text and is dropped when it changes" {
    var t = testText();
    defer t.deinit();
    try put(&t, "one two\n");
    t.select(4, 7);
    try put(&t, "more\n"); // after it
    try std.testing.expectEqual([2]usize{ 4, 7 }, [2]usize{ t.s0, t.s1 });
    _ = try t.insert(&.{ 'a', 'b' }, 0); // before it
    try std.testing.expectEqual([2]usize{ 6, 9 }, [2]usize{ t.s0, t.s1 });
    t.delete(0, 2);
    try std.testing.expectEqual([2]usize{ 4, 7 }, [2]usize{ t.s0, t.s1 });
    t.delete(8, 9); // after it
    try std.testing.expectEqual([2]usize{ 4, 7 }, [2]usize{ t.s0, t.s1 });
    _ = try t.insert(&.{'x'}, 5); // inside it
    try std.testing.expectEqual([2]usize{ 0, 0 }, [2]usize{ t.s0, t.s1 });
    t.select(4, 7);
    t.delete(6, 9); // overlapping it
    try std.testing.expectEqual([2]usize{ 0, 0 }, [2]usize{ t.s0, t.s1 });
}

test "the marked text moves back when the history is cut" {
    var t = testText();
    defer t.deinit();
    const a = std.testing.allocator;
    const big = try a.alloc(Rune, HiWater - 1);
    defer a.free(big);
    @memset(big, 'x');
    try t.write(big);
    t.select(HiWater - 10, HiWater - 5);
    t.org = t.bottom();
    try put(&t, "yy");
    const m = HiWater - LoWater;
    try std.testing.expectEqual([2]usize{ HiWater - 10 - m, HiWater - 5 - m }, [2]usize{ t.s0, t.s1 });
    // marked text that is cut away is no longer marked
    try t.write(big[0 .. HiWater - t.r.items.len - 1]);
    t.select(3, 9);
    t.org = t.bottom();
    try put(&t, "zz");
    try std.testing.expectEqual([2]usize{ 0, 0 }, [2]usize{ t.s0, t.s1 });
}

test "pasting is typing without the keys' meanings" {
    var t = testText();
    defer t.deinit();
    try put(&t, "% ");
    try t.paste(&.{ 'l', 's', Kdel, Knack });
    try std.testing.expectEqual(6, t.q0);
    try std.testing.expect(!t.readable());
    try t.paste(&.{'\n'});
    try std.testing.expect(t.readable());
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ls\x7f\x15\n", b[0..t.read(&b)]);
    // raw: not shown, read as typed
    _ = try t.ctl("rawon");
    try t.paste(&.{ 'a', 'b' });
    try std.testing.expectEqualStrings("ab", b[0..t.read(&b)]);
    try std.testing.expectEqual(7, t.r.items.len);
}
