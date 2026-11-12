//! Runes and UTF-8, as Plan 9 encodes them.
//! from libc/port/rune.c (chartorune, runetochar, runelen, fullrune)
//! and utflen.c, utfrune.c
//!
//! Plan 9's decoder is not Zig's std.unicode: it accepts the surrogates
//! D800-DFFF and decodes anything else it does not like as Runeerror, one
//! byte long.  The commands have to match the stock ones byte for byte,
//! so they use these.
//!
//! DIFF: strings are slices.  Where the C reads past the end of a short
//! sequence into the string's 0, a byte past the end of the slice counts
//! as that 0, which makes the sequence bad in the same way.

pub const Rune = u21;

pub const UTFmax = 4; // maximum bytes per rune
pub const Runesync = 0x80; // cannot represent part of a UTF sequence (<)
pub const Runeself = 0x80; // rune and UTF sequences are the same (<)
pub const Runeerror = 0xFFFD; // decoding error in UTF
pub const Runemax = 0x10FFFF; // 21-bit rune

const Bit1 = 7;
const Bitx = 6;
const Bit2 = 5;
const Bit3 = 4;
const Bit4 = 3;

const T1 = ((1 << (Bit1 + 1)) - 1) ^ 0xFF; // 0000 0000
const Tx = ((1 << (Bitx + 1)) - 1) ^ 0xFF; // 1000 0000
const T2 = ((1 << (Bit2 + 1)) - 1) ^ 0xFF; // 1100 0000
const T3 = ((1 << (Bit3 + 1)) - 1) ^ 0xFF; // 1110 0000
const T4 = ((1 << (Bit4 + 1)) - 1) ^ 0xFF; // 1111 0000
const T5 = ((1 << (Bit4 + 0)) - 1) ^ 0xFF; // 1111 1000

const Rune1 = (1 << (Bit1 + 0 * Bitx)) - 1; // 0000 0000 0111 1111
const Rune2 = (1 << (Bit2 + 1 * Bitx)) - 1; // 0000 0111 1111 1111
const Rune3 = (1 << (Bit3 + 2 * Bitx)) - 1; // 1111 1111 1111 1111
const Rune4 = (1 << (Bit4 + 3 * Bitx)) - 1; // 0001 1111 1111 1111 1111 1111

const Maskx = (1 << Bitx) - 1; // 0011 1111
const Testx = Maskx ^ 0xFF; // 1100 0000

const Bad = Runeerror;

fn at(s: []const u8, i: usize) u32 {
    return if (i < s.len) s[i] else 0;
}

/// The rune at the start of s and the number of bytes it takes.
pub fn chartorune(s: []const u8) struct { r: Rune, n: usize } {
    // one character sequence
    //    00000-0007F => T1
    const c = at(s, 0);
    if (c < Tx)
        return .{ .r = @intCast(c), .n = 1 };

    // two character sequence
    //    0080-07FF => T2 Tx
    const c1 = at(s, 1) ^ Tx;
    if (c1 & Testx != 0)
        return .{ .r = Bad, .n = 1 };
    if (c < T3) {
        if (c < T2)
            return .{ .r = Bad, .n = 1 };
        const l = ((c << Bitx) | c1) & Rune2;
        if (l <= Rune1)
            return .{ .r = Bad, .n = 1 };
        return .{ .r = @intCast(l), .n = 2 };
    }

    // three character sequence
    //    0800-FFFF => T3 Tx Tx
    const c2 = at(s, 2) ^ Tx;
    if (c2 & Testx != 0)
        return .{ .r = Bad, .n = 1 };
    if (c < T4) {
        const l = ((((c << Bitx) | c1) << Bitx) | c2) & Rune3;
        if (l <= Rune2)
            return .{ .r = Bad, .n = 1 };
        return .{ .r = @intCast(l), .n = 3 };
    }

    // four character sequence
    //    10000-10FFFF => T4 Tx Tx Tx
    const c3 = at(s, 3) ^ Tx;
    if (c3 & Testx != 0)
        return .{ .r = Bad, .n = 1 };
    if (c < T5) {
        const l = ((((((c << Bitx) | c1) << Bitx) | c2) << Bitx) | c3) & Rune4;
        if (l <= Rune3 or l > Runemax)
            return .{ .r = Bad, .n = 1 };
        return .{ .r = @intCast(l), .n = 4 };
    }

    // bad decoding
    return .{ .r = Bad, .n = 1 };
}

/// Encode r into buf (at least UTFmax bytes); returns the length.  A
/// rune past Runemax is encoded as Runeerror.
pub fn runetochar(buf: []u8, r: u32) usize {
    var c = r;
    if (c > Runemax)
        c = Runeerror;

    // one character sequence
    //    00000-0007F => 00-7F
    if (c <= Rune1) {
        buf[0] = @intCast(c);
        return 1;
    }

    // two character sequence
    //    0080-07FF => T2 Tx
    if (c <= Rune2) {
        buf[0] = @intCast(T2 | (c >> 1 * Bitx));
        buf[1] = @intCast(Tx | (c & Maskx));
        return 2;
    }

    // three character sequence
    //    0800-FFFF => T3 Tx Tx
    if (c <= Rune3) {
        buf[0] = @intCast(T3 | (c >> 2 * Bitx));
        buf[1] = @intCast(Tx | ((c >> 1 * Bitx) & Maskx));
        buf[2] = @intCast(Tx | (c & Maskx));
        return 3;
    }

    // four character sequence
    //    10000-1FFFFF => T4 Tx Tx Tx
    buf[0] = @intCast(T4 | (c >> 3 * Bitx));
    buf[1] = @intCast(Tx | ((c >> 2 * Bitx) & Maskx));
    buf[2] = @intCast(Tx | ((c >> 1 * Bitx) & Maskx));
    buf[3] = @intCast(Tx | (c & Maskx));
    return 4;
}

/// The number of bytes r takes.
pub fn runelen(r: u32) usize {
    var buf: [UTFmax]u8 = undefined;
    return runetochar(&buf, r);
}

/// Whether s starts with a complete rune.
pub fn fullrune(s: []const u8) bool {
    if (s.len == 0)
        return false;
    const c = s[0];
    if (c < Tx)
        return true;
    if (c < T3)
        return s.len >= 2;
    if (c < T4)
        return s.len >= 3;
    return s.len >= 4;
}

/// The number of runes in s.
/// DIFF: the C stops at a 0 byte; a slice has its length.
pub fn utflen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] < Runeself)
            i += 1
        else
            i += chartorune(s[i..]).n;
    }
    return n;
}

/// The index in s of the first rune r, or null.
pub fn utfrune(s: []const u8, r: Rune) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        const d = chartorune(s[i..]);
        if (d.r == r)
            return i;
        i += d.n;
    }
    return null;
}
