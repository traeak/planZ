//! Buffered input and output.
//! from libbio: binit.c, bflush.c, bgetc.c, bputc.c, bread.c, bwrite.c,
//! brdline.c, bprint.c (bvprint.c) and bio.h
//!
//! The buffer works as in C: icount and ocount are negative counts of
//! the bytes between a position and the end of the buffer (ebuf); here
//! bbuf, ebuf and gbuf are indices into b, and Bungetsize bytes before
//! bbuf are kept for Bungetc.
//!
//! DIFF:
//!   - Methods on Biobuf.  Brdline returns the line as a slice (the
//!     delimiter included), or null; Blinelen is still there for what is
//!     left when a line does not fit or the file ends without one.
//!   - Bgetc returns null at end of file or on error, not Beof.
//!   - Bread and Bwrite return error.Plan9 on error; Bwrite's error
//!     keeps the C's rule that an interrupted write does not make the
//!     buffer inactive.
//!   - No Berror hook (the C's errorf is nil by default), no Bstr, no
//!     Bopen/Bfdopen (open the file and init a Biobuf), no runes, no
//!     Bseek or Boffset yet.
//!   - print formats with src/lib/fmt.zig through a small buffer that is
//!     written with Bwrite; the C formats straight into the Biobuf.
//!   - A writer is flushed at exit through libc.atexit, as in C.

const std = @import("std");
const fmt = @import("fmt");
const sys = @import("sys.zig");
const libc = @import("libc.zig");

const Error = libc.Error;

pub const Bsize = 32768; // IOUNIT
pub const Bungetsize = 4 + 1; // space for ungetc: UTFmax+1

const State = enum { inactive, ractive, wactive, racteof };

/// The writers to flush at exit.
var wbufs: [20]?*Biobuf = @splat(null);
var atexitflag = false;

fn batexit() void {
    for (&wbufs) |*w| {
        if (w.*) |bp| {
            w.* = null;
            bp.flush() catch {};
        }
    }
}

fn deinstall(bp: *Biobuf) void {
    for (&wbufs) |*w| {
        if (w.* == bp)
            w.* = null;
    }
}

fn install(bp: *Biobuf) void {
    deinstall(bp);
    for (&wbufs) |*w| {
        if (w.* == null) {
            w.* = bp;
            break;
        }
    }
    if (!atexitflag) {
        atexitflag = true;
        _ = libc.atexit(batexit);
    }
}

pub const Biobuf = struct {
    icount: i32 = 0, // neg num of bytes at eob
    ocount: i32 = 0, // num of bytes at bob
    nrdline: i32 = 0, // num of bytes after rdline (the C's rdline)
    state: State = .inactive, // r/w/inactive
    fid: i32 = -1, // open file
    offset: i64 = 0, // offset of buffer in file
    bsize: i32 = 0, // size of buffer
    bbuf: usize = 0, // pointer to beginning of buffer
    ebuf: usize = 0, // pointer to end of buffer
    gbuf: usize = 0, // pointer to good data in buf
    b: [Bungetsize + Bsize]u8 = undefined,

    /// Binit: set bp up to read (OREAD) or write (OWRITE) fd.
    pub fn init(bp: *Biobuf, f: i32, mode: u32) void {
        const p = Bungetsize; // make room for Bungets
        const size: i32 = Bsize;
        switch (mode & ~@as(u32, sys.OCEXEC | sys.ORCLOSE | sys.OTRUNC)) {
            sys.OREAD => {
                bp.state = .ractive;
                bp.ocount = 0;
            },
            sys.OWRITE => {
                install(bp);
                bp.state = .wactive;
                bp.ocount = -size;
            },
            else => {
                libc.fprint(2, "Binits: unknown mode %d\n", .{mode});
                bp.state = .inactive;
                return;
            },
        }
        bp.bbuf = p;
        bp.ebuf = p + Bsize;
        bp.bsize = size;
        bp.icount = 0;
        bp.gbuf = bp.ebuf;
        bp.fid = f;
        bp.nrdline = 0;
        bp.offset = 0;
    }

    /// Bterm: flush and forget; the file is the caller's to close.
    pub fn term(bp: *Biobuf) Error!void {
        deinstall(bp);
        return bp.flush();
    }

    fn iof(bp: *Biobuf, at: usize, n: usize) isize {
        return switch (bp.state) {
            .wactive => sys.write(bp.fid, bp.b[at..][0..n]),
            else => sys.read(bp.fid, bp.b[at..][0..n]),
        };
    }

    fn ebufat(bp: *Biobuf, i: i32) usize {
        return @intCast(@as(i64, @intCast(bp.ebuf)) + i);
    }

    pub fn flush(bp: *Biobuf) Error!void {
        switch (bp.state) {
            .wactive => {
                const n: usize = @intCast(bp.bsize + bp.ocount);
                if (n == 0)
                    return;
                const c = bp.iof(bp.bbuf, n);
                if (c == n) {
                    bp.offset += @intCast(n);
                    bp.ocount = -bp.bsize;
                    return;
                }
                bp.state = .inactive;
                bp.ocount = 0;
            },
            .racteof, .ractive => {
                bp.state = .ractive;
                bp.icount = 0;
                bp.gbuf = bp.ebuf;
                return;
            },
            .inactive => {},
        }
        return error.Plan9;
    }

    /// Bgetc: the next byte, or null at end of file or on error.
    pub fn getc(bp: *Biobuf) ?u8 {
        while (true) {
            const i = bp.icount;
            if (i != 0) {
                bp.icount = i + 1;
                return bp.b[bp.ebufat(i)];
            }
            if (bp.state != .ractive) {
                if (bp.state == .racteof)
                    bp.state = .ractive;
                return null;
            }
            // get next buffer, try to keep Bungetsize
            // characters pre-catenated from the previous
            // buffer to allow that many ungets.
            std.mem.copyForwards(u8, bp.b[bp.bbuf - Bungetsize .. bp.bbuf], bp.b[bp.ebuf - Bungetsize .. bp.ebuf]);
            const r = bp.iof(bp.bbuf, @intCast(bp.bsize));
            bp.gbuf = bp.bbuf;
            if (r <= 0) {
                bp.state = .racteof;
                if (r < 0)
                    bp.state = .inactive;
                return null;
            }
            const n: usize = @intCast(r);
            if (n < bp.bsize) {
                std.mem.copyBackwards(u8, bp.b[bp.ebuf - n - Bungetsize .. bp.ebuf], bp.b[bp.bbuf - Bungetsize .. bp.bbuf + n]);
                bp.gbuf = bp.ebuf - n;
            }
            bp.icount = -@as(i32, @intCast(n));
            bp.offset += @intCast(n);
        }
    }

    /// Bungetc: give back the last byte Bgetc returned.
    pub fn ungetc(bp: *Biobuf) bool {
        if (bp.state == .racteof)
            bp.state = .ractive;
        if (bp.state != .ractive)
            return false;
        bp.icount -= 1;
        return true;
    }

    /// Bread: up to buf.len bytes; 0 at end of file.
    pub fn read(bp: *Biobuf, buf: []u8) Error!usize {
        var c = buf.len;
        var p: usize = 0;
        var ic = bp.icount;
        while (c > 0) {
            var n: usize = @intCast(-ic);
            if (n > c)
                n = c;
            if (n == 0) {
                if (bp.state != .ractive)
                    break;
                const r = bp.iof(bp.bbuf, @intCast(bp.bsize));
                if (r <= 0) {
                    bp.state = .racteof;
                    if (r < 0)
                        bp.state = .inactive;
                    break;
                }
                const i: usize = @intCast(r);
                bp.gbuf = bp.bbuf;
                bp.offset += @intCast(i);
                if (i < bp.bsize) {
                    std.mem.copyBackwards(u8, bp.b[bp.ebuf - i .. bp.ebuf], bp.b[bp.bbuf .. bp.bbuf + i]);
                    bp.gbuf = bp.ebuf - i;
                }
                ic = -@as(i32, @intCast(i));
                continue;
            }
            @memcpy(buf[p..][0..n], bp.b[bp.ebufat(ic)..][0..n]);
            c -= n;
            ic += @intCast(n);
            p += n;
        }
        bp.icount = ic;
        if (c == buf.len and bp.state == .inactive)
            return error.Plan9;
        return buf.len - c;
    }

    /// Bwrite: all of buf, or an error.
    pub fn write(bp: *Biobuf, buf: []const u8) Error!usize {
        var c = buf.len;
        var p: usize = 0;
        var oc = bp.ocount;
        while (c > 0) {
            var n: usize = @intCast(-oc);
            if (n > c)
                n = c;
            if (n == 0) {
                if (bp.state != .wactive)
                    return error.Plan9;
                const i = bp.iof(bp.bbuf, @intCast(bp.bsize));
                if (i != bp.bsize) {
                    var eb: [libc.ERRMAX]u8 = undefined;
                    if (std.mem.indexOf(u8, libc.rerrstr(&eb), "interrupt") == null)
                        bp.state = .inactive;
                    return error.Plan9;
                }
                bp.offset += i;
                oc = -bp.bsize;
                continue;
            }
            @memcpy(bp.b[bp.ebufat(oc)..][0..n], buf[p..][0..n]);
            oc += @intCast(n);
            c -= n;
            p += n;
        }
        bp.ocount = oc;
        return buf.len - c;
    }

    /// Bputc
    pub fn putc(bp: *Biobuf, c: u8) Error!void {
        while (true) {
            const i = bp.ocount;
            if (i != 0) {
                bp.b[bp.ebufat(i)] = c;
                bp.ocount = i + 1;
                return;
            }
            try bp.flush();
        }
    }

    /// Brdline: the next line, delim included, as a slice of the buffer
    /// (valid until the next read), or null at end of file, on error, or
    /// when the line does not fit; linelen() then says how much is there.
    pub fn rdline(bp: *Biobuf, delim: u8) ?[]u8 {
        var i: usize = @intCast(-bp.icount);
        if (i == 0) {
            // eof or other error
            if (bp.state != .ractive) {
                if (bp.state == .racteof)
                    bp.state = .ractive;
                bp.nrdline = 0;
                bp.gbuf = bp.ebuf;
                return null;
            }
        }

        // first try in remainder of buffer (gbuf doesn't change)
        var ip = bp.ebuf - i;
        if (std.mem.findScalar(u8, bp.b[ip..][0..i], delim)) |e| {
            const j = e + 1;
            bp.nrdline = @intCast(j);
            bp.icount += @intCast(j);
            return bp.b[ip..][0..j];
        }

        // copy data to beginning of buffer
        if (i < bp.bsize)
            std.mem.copyForwards(u8, bp.b[bp.bbuf..][0..i], bp.b[ip..][0..i]);
        bp.gbuf = bp.bbuf;

        // append to buffer looking for the delim
        ip = bp.bbuf + i;
        const bsize: usize = @intCast(bp.bsize);
        while (i < bsize) {
            const r = bp.iof(ip, bsize - i);
            if (r <= 0) {
                // end of file with no delim
                std.mem.copyBackwards(u8, bp.b[bp.ebuf - i .. bp.ebuf], bp.b[bp.bbuf..][0..i]);
                bp.nrdline = @intCast(i);
                bp.icount = -@as(i32, @intCast(i));
                bp.gbuf = bp.ebuf - i;
                return null;
            }
            const j: usize = @intCast(r);
            bp.offset += @intCast(j);
            i += j;
            if (std.mem.findScalar(u8, bp.b[ip..][0..j], delim)) |e| {
                // found in new piece
                // copy back up and reset everything
                const ep = ip + e;
                const nip = bp.ebuf - i;
                if (i < bsize) {
                    std.mem.copyBackwards(u8, bp.b[nip..][0..i], bp.b[bp.bbuf..][0..i]);
                    bp.gbuf = nip;
                }
                const l = (ep - bp.bbuf) + 1;
                bp.nrdline = @intCast(l);
                bp.icount = @as(i32, @intCast(l)) - @as(i32, @intCast(i));
                return bp.b[nip..][0..l];
            }
            ip += j;
        }

        // full buffer without finding
        bp.nrdline = bp.bsize;
        bp.icount = -bp.bsize;
        bp.gbuf = bp.bbuf;
        return null;
    }

    /// Blinelen: the length of the last line rdline returned, or of what
    /// it left when it returned null.
    pub fn linelen(bp: *Biobuf) usize {
        return @intCast(bp.nrdline);
    }

    /// Bprint, with the verbs of src/lib/fmt.zig.
    pub fn print(bp: *Biobuf, comptime format: []const u8, args: anytype) Error!void {
        const S = struct {
            fn flush(f: *fmt.Fmt) void {
                const b: *Biobuf = @ptrCast(@alignCast(f.farg.?));
                _ = b.write(f.buf[0..f.n]) catch {};
                f.n = 0;
            }
        };
        var tmp: [256]u8 = undefined;
        var f: fmt.Fmt = .{ .buf = &tmp, .flush = S.flush, .farg = bp };
        fmt.errstr = libc.errtext;
        fmt.fmtprint(&f, format, args);
        S.flush(&f);
        if (bp.state == .inactive)
            return error.Plan9;
    }
};
