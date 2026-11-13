//! Floating point as 9front's libc does it: strtod, ldexp, frexp, modf,
//! pow10, NaN, Inf, isNaN and isInf.
//! from libc/port: strtod.c, frexp.c, pow10.c, nan.c, and the amd64
//! umuldiv in libc/amd64/muldiv.s
//!
//! fmt.zig's %e %f %g get their digits by converting a guess back with
//! strtod, so the digits they settle on depend on this strtod: it is
//! ported as it is, not replaced with Zig's parser.
//!
//! DIFF:
//!   - strtod takes a slice and returns the value and how many bytes it
//!     used (the C's *aas); the end of the slice, or a 0 byte, ends the
//!     number as the C's terminator does.
//!   - The digit buffer works with lengths: the C keeps a 0 after the
//!     digits that its loops stop on.  It is 4096 bytes, not 1500: the
//!     C's overflows when 1450 digits meet an exponent that adds a few
//!     hundred more while it is scaled.
//!   - FPdbleword's hi and lo words are the upper and lower halves of
//!     the double's bits.

const std = @import("std");

// ---------------------------------------------------------------- nan.c

const NANEXP: u32 = 2047 << 20;
const NANMASK: u32 = 2047 << 20;
const NANSIGN: u32 = 1 << 31;

fn hi(d: f64) u32 {
    return @truncate(@as(u64, @bitCast(d)) >> 32);
}

fn lo(d: f64) u32 {
    return @truncate(@as(u64, @bitCast(d)));
}

fn mk(h: u32, l: u32) f64 {
    return @bitCast(@as(u64, h) << 32 | l);
}

pub fn NaN() f64 {
    return mk(NANEXP, 1);
}

pub fn isNaN(d: f64) bool {
    if (hi(d) & NANMASK != NANEXP)
        return false;
    return !isInf(d, 0);
}

pub fn Inf(sign: i32) f64 {
    return mk(if (sign < 0) NANEXP | NANSIGN else NANEXP, 0);
}

pub fn isInf(d: f64, sign: i32) bool {
    if (lo(d) != 0)
        return false;
    if (hi(d) == NANEXP)
        return sign >= 0;
    if (hi(d) == NANEXP | NANSIGN)
        return sign <= 0;
    return false;
}

// -------------------------------------------------------------- frexp.c

const MASK: u32 = 0x7ff;
const SHIFT = 20;
const BIAS: i32 = 1022;
const SIG = 52;

/// The fraction in [0.5, 1) and the power of 2: d = fraction * 2^e.
pub fn frexp(d: f64) struct { f: f64, e: i32 } {
    var e: i32 = 0;
    // order matters: only isNaN can operate on NaN
    if (isNaN(d) or isInf(d, 0) or d == 0)
        return .{ .f = d, .e = 0 };
    var x = d;
    if (hi(@abs(d)) >> SHIFT == 0) { // normalize subnormal numbers
        x = @as(f64, @floatFromInt(@as(u64, 1) << SIG)) * d;
        e = -SIG;
    }
    e += @as(i32, @intCast((hi(x) >> SHIFT) & MASK)) - BIAS;
    var h = hi(x);
    h &= ~(MASK << SHIFT);
    h |= @as(u32, @intCast(BIAS)) << SHIFT;
    return .{ .f = mk(h, lo(x)), .e = e };
}

pub fn ldexp(d: f64, deltae_: i32) f64 {
    var deltae = deltae_;
    if (d == 0)
        return 0;
    var h = hi(d);
    var l = lo(d);
    var e: i32 = @intCast((h >> SHIFT) & MASK);
    if (deltae >= 0 or e + deltae >= 1) { // no underflow
        e += deltae;
        if (e >= MASK) { // overflow
            if (d < 0)
                return Inf(-1);
            return Inf(1);
        }
    } else { // underflow gracefully
        deltae = -deltae;
        // need to shift d right deltae
        if (e > 1) { // shift e-1 by exponent manipulation
            deltae -= e - 1;
            e = 1;
        }
        if (deltae > 0 and e == 1) { // shift 1 by switch from 1.fff to 0.1ff
            deltae -= 1;
            e = 0;
            l >>= 1;
            l |= (h & 1) << 31;
            const z = h & ((1 << SHIFT) - 1);
            h &= ~@as(u32, (1 << SHIFT) - 1);
            h |= (1 << (SHIFT - 1)) | (z >> 1);
        }
        while (deltae > 0) { // shift bits down
            var bits: u5 = undefined;
            bits = @intCast(@min(deltae, SHIFT));
            l >>= bits;
            l |= (h & ((@as(u32, 1) << bits) - 1)) << @intCast(32 - @as(u6, bits));
            const z = h & ((1 << SHIFT) - 1);
            h &= ~@as(u32, (1 << SHIFT) - 1);
            h |= z >> bits;
            deltae -= bits;
        }
    }
    h &= ~(MASK << SHIFT);
    h |= @as(u32, @bitCast(e)) << SHIFT;
    return mk(h, l);
}

/// The fraction and integer parts: d = f + i, both with d's sign.
pub fn modf(d: f64) struct { f: f64, i: f64 } {
    var h = hi(d);
    var l = lo(d);
    var e: i32 = @intCast((h >> SHIFT) & MASK);
    if (e == MASK) {
        if (l != 0 or (h & 0xfffff) != 0) // NaN
            return .{ .f = d, .i = d };
        // ±Inf
        return .{ .f = mk(h & 0x80000000, 0), .i = d };
    }
    if (d < 1) {
        if (d < 0) {
            const m = modf(-d);
            return .{ .f = -m.f, .i = -m.i };
        }
        return .{ .f = d, .i = 0 };
    }
    e -= BIAS;
    if (e <= SHIFT + 1) {
        h &= ~(@as(u32, 0x1fffff) >> @intCast(e));
        l = 0;
    } else if (e <= SHIFT + 33)
        l &= ~(@as(u32, 0x7fffffff) >> @intCast(e - SHIFT - 2));
    const ip = mk(h, l);
    return .{ .f = d - ip, .i = ip };
}

// -------------------------------------------------------------- pow10.c

const tab = [_]f64{
    1.0e0, 1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
    1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17, 1.0e18, 1.0e19,
    1.0e20, 1.0e21, 1.0e22, 1.0e23, 1.0e24, 1.0e25, 1.0e26, 1.0e27, 1.0e28, 1.0e29,
    1.0e30, 1.0e31, 1.0e32, 1.0e33, 1.0e34, 1.0e35, 1.0e36, 1.0e37, 1.0e38, 1.0e39,
    1.0e40, 1.0e41, 1.0e42, 1.0e43, 1.0e44, 1.0e45, 1.0e46, 1.0e47, 1.0e48, 1.0e49,
    1.0e50, 1.0e51, 1.0e52, 1.0e53, 1.0e54, 1.0e55, 1.0e56, 1.0e57, 1.0e58, 1.0e59,
    1.0e60, 1.0e61, 1.0e62, 1.0e63, 1.0e64, 1.0e65, 1.0e66, 1.0e67, 1.0e68, 1.0e69,
    1.0e70, 1.0e71, 1.0e72, 1.0e73, 1.0e74, 1.0e75, 1.0e76, 1.0e77, 1.0e78, 1.0e79,
    1.0e80, 1.0e81, 1.0e82, 1.0e83, 1.0e84, 1.0e85, 1.0e86, 1.0e87, 1.0e88, 1.0e89,
    1.0e90, 1.0e91, 1.0e92, 1.0e93, 1.0e94, 1.0e95, 1.0e96, 1.0e97, 1.0e98, 1.0e99,
    1.0e100, 1.0e101, 1.0e102, 1.0e103, 1.0e104, 1.0e105, 1.0e106, 1.0e107, 1.0e108, 1.0e109,
    1.0e110, 1.0e111, 1.0e112, 1.0e113, 1.0e114, 1.0e115, 1.0e116, 1.0e117, 1.0e118, 1.0e119,
    1.0e120, 1.0e121, 1.0e122, 1.0e123, 1.0e124, 1.0e125, 1.0e126, 1.0e127, 1.0e128, 1.0e129,
    1.0e130, 1.0e131, 1.0e132, 1.0e133, 1.0e134, 1.0e135, 1.0e136, 1.0e137, 1.0e138, 1.0e139,
    1.0e140, 1.0e141, 1.0e142, 1.0e143, 1.0e144, 1.0e145, 1.0e146, 1.0e147, 1.0e148, 1.0e149,
    1.0e150, 1.0e151, 1.0e152, 1.0e153, 1.0e154, 1.0e155, 1.0e156, 1.0e157, 1.0e158, 1.0e159,
};

pub fn pow10(n_: i32) f64 {
    var n = n_;
    if (n < 0) {
        n = -n;
        if (n < tab.len)
            return 1 / tab[@intCast(n)];
        const m = @divTrunc(n, 2);
        return 1 / (pow10(m) * pow10(n - m));
    }
    if (n < tab.len)
        return tab[@intCast(n)];
    const m = @divTrunc(n, 2);
    return pow10(m) * pow10(n - m);
}

// ----------------------------------------- floor.c, fmod.c, fabs.c

pub fn floor(d_: f64) f64 {
    var d = d_;
    if (d < 0) {
        const m = modf(-d);
        d = m.i;
        if (m.f != 0.0)
            d += 1;
        d = -d;
    } else d = modf(d).i;
    return d;
}

pub fn ceil(d: f64) f64 {
    return -floor(-d);
}

/// floating-point mod function without infinity or NaN checking
pub fn fmod(x: f64, y_: f64) f64 {
    var y = y_;
    if (y == 0)
        return x;
    if (y < 0)
        y = -y;
    const yf = frexp(y);
    var sign = false;
    var r: f64 = undefined;
    if (x < 0) {
        r = -x;
        sign = true;
    } else r = x;
    while (r >= y) {
        const rf = frexp(r);
        r -= ldexp(y, rf.e - yf.e - @intFromBool(rf.f < yf.f));
    }
    if (sign)
        r = -r;
    return r;
}

pub fn fabs(arg: f64) f64 {
    if (arg < 0)
        return -arg;
    return arg;
}

/// The SSE square root, as libc/amd64/sqrt.s.
pub fn sqrt(d: f64) f64 {
    return @sqrt(d);
}

// ------------------------------------------------------------- strtod.c

// This routine will convert to arbitrary precision
// floating point entirely in multi-precision fixed.
// The answer is the closest floating point number to
// the given decimal number. Exactly half way are
// rounded ala ieee rules.
// Method is to scale input decimal between .500 and .999...
// with external power of 2, then binary search for the
// closest mantissa to this decimal number.
// Nmant is is the required precision. (53 for ieee dp)
// Nbits is the max number of bits/word. (must be <= 28)
// Prec is calculated - the number of words of fixed mantissa.
const Nbits = 28; // bits safely represented in a ulong
const Nmant = 53; // bits of precision required
const Bias = 1022;
const Prec = (Nmant + Nbits + 1) / Nbits; // words of Nbits each to represent mantissa
const Sigbit: u32 = 1 << (Prec * Nbits - Nmant); // first significant bit of Prec-th word
const Ndig = 1500;
const One: u32 = 1 << Nbits;
const Half: u32 = One >> 1;
const Maxe = 310;

const Fsign = 1 << 0; // found -
const Fesign = 1 << 1; // found e-
const Fdpoint = 1 << 2; // found .

const State = enum { S0, S1, S2, S3, S4, S5, S6, S7 };

const SIGN: u32 = 1 << 31;

/// The decimal digits being scaled, as ASCII.
const Digits = struct {
    a: [4096]u8 = undefined,
    na: usize = 0,

    /// The digit at i, or the C's 0 past the end.
    fn at(d: *const Digits, i: usize) u8 {
        return if (i < d.na) d.a[i] else 0;
    }

    /// memcmp(a, s, s.len): the digits past the end are the C's 0.
    fn cmp(d: *const Digits, s: []const u8) i32 {
        for (s, 0..) |c, i| {
            const x = d.at(i);
            if (x != c)
                return if (x < c) -1 else 1;
            if (x == 0) break;
        }
        return 0;
    }
};

/// The value of the number at the start of s, and how many bytes of s
/// it took (0 if there is none).
pub fn strtod(s_: []const u8) struct { v: f64, n: usize } {
    const s = s_[0 .. std.mem.findScalar(u8, s_, 0) orelse s_.len];
    var flag: u32 = 0; // Fsign, Fesign, Fdpoint
    var dg: Digits = .{}; // the C's a[] and na
    var dp: i32 = 0; // na of decimal point
    var ex: i32 = 0; // exonent

    var state: State = .S0;
    var i: usize = 0;
    scan: while (true) : (i += 1) {
        const c: u8 = if (i < s.len) s[i] else 0;
        if (c >= '0' and c <= '9') {
            switch (state) {
                .S0, .S1, .S2 => state = .S2,
                .S3, .S4 => state = .S4,
                .S5, .S6, .S7 => {
                    state = .S7;
                    ex = ex *% 10 +% (c - '0');
                    continue;
                },
            }
            if (dg.na == 0 and c == '0') {
                dp -= 1;
                continue;
            }
            if (dg.na < Ndig - 50) {
                dg.a[dg.na] = c;
                dg.na += 1;
            }
            continue;
        }
        switch (c) {
            '\t', '\n', 0x0b, 0x0c, '\r', ' ' => {
                if (state == .S0)
                    continue;
            },
            '-', '+' => {
                if (c == '-') {
                    if (state == .S0)
                        flag |= Fsign
                    else
                        flag |= Fesign;
                }
                if (state == .S0)
                    state = .S1
                else if (state == .S5)
                    state = .S6
                else
                    break :scan; // syntax
                continue;
            },
            '.' => {
                flag |= Fdpoint;
                dp = @intCast(dg.na);
                if (state == .S0 or state == .S1) {
                    state = .S3;
                    continue;
                }
                if (state == .S2) {
                    state = .S4;
                    continue;
                }
            },
            'e', 'E' => {
                if (state == .S2 or state == .S4) {
                    state = .S5;
                    continue;
                }
            },
            else => {},
        }
        break;
    }

    // clean up return char-pointer
    var end = i;
    switch (state) {
        .S0, .S1 => {
            if (xcmp(s[i..], "nan"))
                return .{ .v = retnan(flag), .n = i + 3 };
            if (xcmp(s[i..], "infinity"))
                return .{ .v = Inf(-@as(i32, @intCast(flag & Fsign))), .n = i + 8 };
            if (xcmp(s[i..], "inf"))
                return .{ .v = Inf(-@as(i32, @intCast(flag & Fsign))), .n = i + 3 };
            return .{ .v = ret0(flag), .n = 0 }; // no digits found
        },
        .S3 => return .{ .v = ret0(flag), .n = 0 }, // no digits found
        .S6 => end -= 2, // back over +- and e
        .S5 => end -= 1, // back over e
        else => {},
    }

    if (flag & Fdpoint != 0) {
        while (dg.na > 0 and dg.a[dg.na - 1] == '0')
            dg.na -= 1;
    }
    if (dg.na == 0)
        return .{ .v = ret0(flag), .n = end }; // zero
    if (flag & Fdpoint == 0)
        dp = @intCast(dg.na);
    if (flag & Fesign != 0)
        ex = -%ex;
    dp +%= ex;
    if (dp < -Maxe - Nmant / 3) // actually -Nmant*log(2)/log(10), but Nmant/3 close enough
        return .{ .v = ret0(flag), .n = end } // underflow by exp
    else if (dp > Maxe)
        return .{ .v = Inf(-@as(i32, @intCast(flag & Fsign))), .n = end }; // overflow by exp

    // normalize the decimal ascii number
    // to range .[5-9][0-9]* e0
    var bp: i32 = 0; // binary exponent
    while (dp > 0)
        divascii(&dg, &dp, &bp);
    while (dp < 0 or dg.at(0) < '5')
        mulascii(&dg, &dp, &bp);

    // very small numbers are represented using
    // bp = -Bias+1.  adjust accordingly.
    if (bp < -Bias + 1) {
        const ona = dg.na;
        divby(&dg, @intCast(-bp - Bias + 1));
        if (dg.na < ona) {
            const n = dg.na;
            std.mem.copyBackwards(u8, dg.a[ona - n .. ona], dg.a[0..n]);
            @memset(dg.a[0 .. ona - n], '0');
            dg.na = ona;
        }
        bp = -Bias + 1;
    }

    // close approx by naive conversion
    var num: u32 = 0;
    var den: u32 = 1;
    var k: usize = 0;
    while (k < 9 and dg.at(k) != 0) : (k += 1) {
        num = num * 10 + (dg.a[k] - '0');
        den *= 10;
    }
    var low: [Prec]u32 = undefined;
    var hig: [Prec]u32 = undefined;
    var mid: [Prec]u32 = undefined;
    low[0] = umuldiv(num, One, den);
    hig[0] = umuldiv(num + 1, One, den);
    for (1..Prec) |j| {
        low[j] = 0;
        hig[j] = One - 1;
    }

    // binary search for closest mantissa
    while (true) {
        // mid = (hig + low) / 2
        var c: u32 = 0;
        for (0..Prec) |j| {
            mid[j] = hig[j] + low[j];
            if (c != 0)
                mid[j] += One;
            c = mid[j] & 1;
            mid[j] >>= 1;
        }
        frnorm(&mid);

        // compare
        const r = fpcmp(&dg, &mid);
        if (r > 0) {
            var same = true;
            for (0..Prec) |j| {
                if (low[j] != mid[j]) {
                    same = false;
                    low[j] = mid[j];
                }
            }
            if (same)
                break; // between mid and hig
            continue;
        }
        if (r < 0) {
            hig = mid;
            continue;
        }

        // only hard part is if even/odd roundings wants to go up
        const x = mid[Prec - 1] & (Sigbit - 1);
        if (x == Sigbit / 2 and (mid[Prec - 1] & Sigbit) == 0)
            mid[Prec - 1] -= x;
        break; // exactly mid
    }

    // normal rounding applies
    const c = mid[Prec - 1] & (Sigbit - 1);
    mid[Prec - 1] -= c;
    if (c >= Sigbit / 2) {
        mid[Prec - 1] += Sigbit;
        frnorm(&mid);
    }
    var d: f64 = 0;
    for (0..Prec) |j|
        d = d * @as(f64, @floatFromInt(One)) + @as(f64, @floatFromInt(mid[j]));
    if (flag & Fsign != 0)
        d = -d;
    return .{ .v = ldexp(d, bp - Prec * Nbits), .n = end };
}

fn ret0(flag: u32) f64 {
    return mk(if (flag & Fsign != 0) SIGN else 0, 0);
}

fn retnan(flag: u32) f64 {
    const n = NaN();
    return mk(if (flag & Fsign != 0) hi(n) | SIGN else hi(n), lo(n));
}

/// (a*b)/c with a 64-bit product and a 32-bit quotient, as the amd64
/// umuldiv.
fn umuldiv(a: u32, b: u32, c: u32) u32 {
    return @truncate(@as(u64, a) * b / c);
}

fn frnorm(f: *[Prec]u32) void {
    var c: u32 = 0;
    var i: usize = Prec - 1;
    while (i > 0) : (i -= 1) {
        f[i] +%= c;
        c = f[i] >> Nbits;
        f[i] &= One - 1;
    }
    f[0] +%= c;
}

fn fpcmp(a: *const Digits, f: *const [Prec]u32) i32 {
    var tf = f.*;
    var k: usize = 0;
    while (true) {
        // tf *= 10
        for (&tf) |*x|
            x.* *%= 10;
        frnorm(&tf);
        const d: u32 = (tf[0] >> Nbits) + '0';
        tf[0] &= One - 1;

        // compare next digit
        const c: u32 = a.at(k);
        if (c == 0) {
            if ('0' < d)
                return -1;
            for (tf) |x| {
                if (x != 0)
                    break;
            } else return 0;
            continue;
        }
        if (c > d)
            return 1;
        if (c < d)
            return -1;
        k += 1;
    }
}

/// Divide the digits by 2^b (b <= 9).  DIFF: the C reads and writes
/// one string and stops at its 0; this reads the na digits there were.
fn _divby(dg: *Digits, b: u5) void {
    const a = &dg.a;
    const len = dg.na;
    var r: usize = 0; // the C's a
    var p: usize = 0;
    var n: u32 = 0;
    var tail = false;
    while (n >> b == 0) {
        if (r >= len) {
            while (n != 0) {
                const c = n * 10;
                if (c >> b != 0)
                    break;
                n = c;
            }
            tail = true;
            break;
        }
        n = n * 10 + (a[r] - '0');
        r += 1;
    }
    if (!tail) {
        while (true) {
            const c = n >> b;
            n -= c << b;
            a[p] = @intCast(c + '0');
            p += 1;
            if (r >= len)
                break;
            n = n * 10 + (a[r] - '0');
            r += 1;
        }
    }
    while (n != 0) {
        n = n * 10;
        const c = n >> b;
        n -= c << b;
        a[p] = @intCast(c + '0');
        p += 1;
    }
    dg.na = p;
}

fn divby(dg: *Digits, b_: i32) void {
    var b = b_;
    while (b > 9) {
        _divby(dg, 9);
        b -= 9;
    }
    if (b > 0)
        _divby(dg, @intCast(b));
}

const Tab = struct { bp: i32, siz: usize, cmp: []const u8 };

const tab1 = [_]Tab{
    .{ .bp = 1, .siz = 0, .cmp = "" },
    .{ .bp = 3, .siz = 1, .cmp = "7" },
    .{ .bp = 6, .siz = 2, .cmp = "63" },
    .{ .bp = 9, .siz = 3, .cmp = "511" },
    .{ .bp = 13, .siz = 4, .cmp = "8191" },
    .{ .bp = 16, .siz = 5, .cmp = "65535" },
    .{ .bp = 19, .siz = 6, .cmp = "524287" },
    .{ .bp = 23, .siz = 7, .cmp = "8388607" },
    .{ .bp = 26, .siz = 8, .cmp = "67108863" },
    .{ .bp = 27, .siz = 9, .cmp = "134217727" },
};

fn divascii(dg: *Digits, dp: *i32, bp: *i32) void {
    var d: i32 = dp.*;
    if (d >= tab1.len)
        d = tab1.len - 1;
    const t = tab1[@intCast(d)];
    const b = t.bp;
    if (dg.cmp(t.cmp[0..t.siz]) > 0)
        d -= 1;
    dp.* -= d;
    bp.* += b;
    divby(dg, b);
}

/// Multiply the digits a[0..q) by 2^b, writing the product so that it
/// ends at p (p > q); the C's mulby.
fn mulby(a: []u8, p_: usize, q_: usize, b: u5) void {
    var p = p_;
    var q = q_;
    var n: u32 = 0;
    while (q > 0) {
        q -= 1;
        var c: u32 = a[q] - '0';
        c = (c << b) + n;
        n = c / 10;
        c -= n * 10;
        p -= 1;
        a[p] = @intCast(c + '0');
    }
    while (n != 0) {
        const c0 = n;
        n = c0 / 10;
        const c = c0 - n * 10;
        p -= 1;
        a[p] = @intCast(c + '0');
    }
}

const tab2 = [_]Tab{
    .{ .bp = 1, .siz = 1, .cmp = "" }, // dp = 0-0
    .{ .bp = 3, .siz = 3, .cmp = "125" },
    .{ .bp = 6, .siz = 5, .cmp = "15625" },
    .{ .bp = 9, .siz = 7, .cmp = "1953125" },
    .{ .bp = 13, .siz = 10, .cmp = "1220703125" },
    .{ .bp = 16, .siz = 12, .cmp = "152587890625" },
    .{ .bp = 19, .siz = 14, .cmp = "19073486328125" },
    .{ .bp = 23, .siz = 17, .cmp = "11920928955078125" },
    .{ .bp = 26, .siz = 19, .cmp = "1490116119384765625" },
    .{ .bp = 27, .siz = 19, .cmp = "7450580596923828125" }, // dp 8-9
};

fn mulascii(dg: *Digits, dp: *i32, bp: *i32) void {
    var d: i32 = -dp.*;
    if (d >= tab2.len)
        d = tab2.len - 1;
    const t = tab2[@intCast(d)];
    const b = t.bp;
    // the C compares siz bytes of "" here (row 0): its terminator, so
    // the digits' first byte against 0
    const cmp = if (t.cmp.len >= t.siz) t.cmp[0..t.siz] else "\x00";
    if (dg.cmp(cmp) < 0)
        d -= 1;
    const p = dg.na;
    bp.* -= b;
    dp.* += d;
    const dn: usize = @intCast(d);
    dg.na += dn;
    mulby(&dg.a, p + dn, p, @intCast(b));
}

/// Whether a starts with b, ignoring case in a.
fn xcmp(a: []const u8, b: []const u8) bool {
    for (b, 0..) |c1, i| {
        var c2: u8 = if (i < a.len) a[i] else 0;
        c2 = std.ascii.toLower(c2);
        if (c1 != c2)
            return false;
    }
    return true;
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn expectBits(s: []const u8, want: f64) !void {
    const got = strtod(s).v;
    if (@as(u64, @bitCast(got)) != @as(u64, @bitCast(want))) {
        std.debug.print("strtod(\"{s}\") = {e} ({x}), want {e} ({x})\n", .{ s, got, @as(u64, @bitCast(got)), want, @as(u64, @bitCast(want)) });
        return error.TestUnexpectedResult;
    }
}

test "strtod: simple numbers and syntax" {
    try expectBits("0", 0);
    try expectBits("-0", -0.0);
    try expectBits("1", 1);
    try expectBits("  -12.5e1x", -125);
    try expectBits(".5", 0.5);
    try expectBits("5.", 5);
    try expectBits("1e", 1);
    try expectBits("1e+", 1);
    try testing.expectEqual(@as(usize, 1), strtod("1e+").n);
    try testing.expectEqual(@as(usize, 1), strtod("1ex").n); // back over the e, as the C does
    try testing.expectEqual(@as(usize, 0), strtod("x").n);
    try testing.expectEqual(@as(usize, 0), strtod(".").n);
    try testing.expect(isNaN(strtod("NaN").v));
    try testing.expect(isInf(strtod("-Infinity").v, -1));
    try testing.expectEqual(@as(usize, 8), strtod("infinity").n);
    try testing.expect(isInf(strtod("1e400").v, 1));
    try expectBits("1e-400", 0);
    try expectBits("0.1", 0.1);
    try expectBits("1.7976931348623157e308", std.math.floatMax(f64));
    try expectBits("2.2250738585072014e-308", std.math.floatMin(f64));
}

test "strtod agrees with a correctly rounded parser" {
    var prng = std.Random.DefaultPrng.init(9);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    var disagree: usize = 0;
    for (0..20000) |k| {
        // random bit patterns printed with 17 digits, and random decimals
        var s: []const u8 = undefined;
        if (k % 2 == 0) {
            const bits = rnd.int(u64) & 0x7fff_ffff_ffff_ffff;
            const v: f64 = @bitCast(bits);
            if (std.math.isNan(v) or std.math.isInf(v)) continue;
            s = std.fmt.bufPrint(&buf, "{e}", .{v}) catch unreachable;
        } else {
            const m = rnd.int(u64) % 100000000000000000;
            const e = rnd.intRangeAtMost(i32, -330, 310);
            s = std.fmt.bufPrint(&buf, "{d}e{d}", .{ m, e }) catch unreachable;
        }
        const want = std.fmt.parseFloat(f64, s) catch continue;
        const got = strtod(s).v;
        if (@as(u64, @bitCast(got)) != @as(u64, @bitCast(want))) {
            if (disagree < 10)
                std.debug.print("strtod(\"{s}\") = {x}, std {x}\n", .{ s, @as(u64, @bitCast(got)), @as(u64, @bitCast(want)) });
            disagree += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), disagree);
}

test "ldexp, frexp, modf, pow10" {
    try testing.expectEqual(@as(f64, 8), ldexp(1, 3));
    try testing.expectEqual(@as(f64, 0.25), ldexp(1, -2));
    const fr = frexp(12);
    try testing.expectEqual(@as(f64, 0.75), fr.f);
    try testing.expectEqual(@as(i32, 4), fr.e);
    const m = modf(-3.25);
    try testing.expectEqual(@as(f64, -0.25), m.f);
    try testing.expectEqual(@as(f64, -3), m.i);
    try testing.expectEqual(@as(f64, 1e10), pow10(10));
    try testing.expectEqual(@as(f64, 1e-3), pow10(-3) * 1);
}
