//! The interface between the audio device and its drivers.
//! from 9/port/audioif.h
//!
//! DIFF:
//!   - The entries return Zig errors where the C returns long or calls
//!     error().  volwrite and ctl get a buffer they may edit: devaudio
//!     has copied what was written into Audiochan.buf.
//!   - A volume table is a slice; the C ends it with a nil name.
//!   - addaudiocard, genaudiovolread and genaudiovolwrite are in
//!     devaudio.zig, as in C; this file has only the types.

const portdat = @import("portdat.zig");
const proc = @import("proc.zig");

const Error = proc.Error;
const Ref = portdat.Ref;

pub const Audio = struct {
    name: []const u8 = "",

    ctlr: ?*anyopaque = null,
    mixer: ?*anyopaque = null,

    audioopenr: Ref = .{},
    audioopenw: Ref = .{},

    read: ?*const fn (adev: *Audio, buf: []u8, off: i64) Error!usize = null,
    write: ?*const fn (adev: *Audio, buf: []const u8, off: i64) Error!usize = null,
    close: ?*const fn (adev: *Audio, mode: u32) Error!void = null,

    volread: ?*const fn (adev: *Audio, buf: []u8, off: i64) Error!usize = null,
    volwrite: ?*const fn (adev: *Audio, buf: []u8, off: i64) Error!usize = null,

    ctl: ?*const fn (adev: *Audio, buf: []u8, off: i64) Error!usize = null,
    status: ?*const fn (adev: *Audio, buf: []u8, off: i64) Error!usize = null,
    buffered: ?*const fn (adev: *Audio) usize = null,

    delay: i32 = 0,
    speed: i32 = 0,

    ctlrno: i32 = 0,
    next: ?*Audio = null,
};

// Volume.type
pub const Left = 0;
pub const Right = 1;
pub const Stereo = 2;
pub const Absolute = 3;

pub const Mono = Left;

pub const Volume = struct {
    name: []const u8,
    reg: i32 = 0,
    range: i32 = 0,
    type: i32 = 0,
    cap: u32 = 0,
};

/// Reads or sets entry `x` of a volume table; the values are in v.
pub const Volfn = *const fn (adev: *Audio, x: usize, v: *[2]i32) i32;
