//! The PS/2 mouse on the i8042's auxiliary port, and the machine's
//! half of /dev/mousectl.
//! from 9/pc/mouse.c
//!
//! DIFF:
//!   - Serial mice are not ported: the `serial` command, Mouseserial,
//!     mouseport and the serial case of setintellimouse are gone (so
//!     is uartmouse, which they need).  `serial` is now an unknown
//!     control message.  devmouse.zig keeps the three serial decoders
//!     (m3mouseputc, m5mouseputc, mouseputc), uncalled.
//!   - Errors are Zig error returns; the waserror in mousectl that
//!     releases mousectlqlock is a defer.  The tsleep in setstream and
//!     disstream can be interrupted, as in the C, and that error now
//!     passes through setabs and the callers of setstream explicitly.
//!   - ps2mouse returns i8042auxenable's error ("no PS2 controller")
//!     after setting mousetype, as the C's error() leaves it.  The
//!     next `ps2` then does nothing, as in the C.
//!   - The statics of ps2mouseputc and synmouseputc are file-level
//!     structs (ps2, syn).
//!   - mousectl is reached from the portable devmouse.zig through
//!     screen.mousectl and its hook screen.archmousectl, which
//!     main.zig sets; the C links the function by name.
//!   - ps2mouseputc and synmouseputc each guard one case in which the
//!     C misbehaves; both are marked DIFF where they stand.

const std = @import("std");
const dat = @import("dat.zig");
const devkbd = @import("devkbd.zig");
const draw = @import("../../libdraw/draw.zig");
const portdat = @import("../../port/portdat.zig");
const ql = @import("../../port/qlock.zig");
const proc = @import("../../port/proc.zig");
const parse = @import("../../port/parse.zig");
const netif = @import("../../port/netif.zig");
const portclock = @import("../../port/portclock.zig");
const devmouse = @import("../../port/devmouse.zig");
const screen = @import("../../port/screen.zig");

const i8042auxenable = devkbd.i8042auxenable;
const i8042auxcmd = devkbd.i8042auxcmd;
const mousetrack = devmouse.mousetrack;
const mouseaccelerate = devmouse.mouseaccelerate;
const lastmousems = devmouse.lastmousems;
const atoi = netif.atoi;
const Dx = draw.Dx;
const Dy = draw.Dy;

const Error = proc.Error;
const QLock = portdat.QLock;
const Cmdbuf = parse.Cmdbuf;
const Cmdtab = parse.Cmdtab;

//
//  mouse types
//
const Mouseother = 0;
const Mouseserial = 1;
const MousePS2 = 2;

//
// bytes which correspond
// to mouse buttons
//
const Mousereleas = 0x8;
const Mouseleft = 0x9;
const Mousemid = 0xc;
const Mouseright = 0xa;

var mousectlqlock: QLock = .{};
var mousetype: i32 = 0;
var intellimouse: bool = false;
var packetsize: i32 = 0;
var resolution: i32 = 0;
var accelerated: i32 = 0;
var mousehwaccel: bool = false;
var synaptic: bool = false;
var disabletouch: bool = false;

const CMaccelerated = 0;
const CMhwaccel = 1;
const CMintellimouse = 2;
const CMlinear = 3;
const CMps2 = 4;
const CMps2intellimouse = 5;
const CMres = 6;
const CMreset = 7;
const CMtouchpad = 8;
const CMsynaptic = 9;

const mousectlmsg = [_]Cmdtab{
    .{ .index = CMaccelerated, .cmd = "accelerated", .narg = 0 },
    .{ .index = CMhwaccel, .cmd = "hwaccel", .narg = 2 },
    .{ .index = CMintellimouse, .cmd = "intellimouse", .narg = 1 },
    .{ .index = CMlinear, .cmd = "linear", .narg = 1 },
    .{ .index = CMps2, .cmd = "ps2", .narg = 1 },
    .{ .index = CMps2intellimouse, .cmd = "ps2intellimouse", .narg = 1 },
    .{ .index = CMres, .cmd = "res", .narg = 0 },
    .{ .index = CMreset, .cmd = "reset", .narg = 1 },
    .{ .index = CMtouchpad, .cmd = "touchpad", .narg = 2 },
    .{ .index = CMsynaptic, .cmd = "synaptic", .narg = 1 },
};

fn now() u32 {
    return portclock.tk2ms(dat.MACHP(0).ticks);
}

/// msg |= 0xFF00: sign extension of a byte kept in a short.
fn signext(v: i16) i16 {
    return @bitCast(@as(u16, @bitCast(v)) | 0xFF00);
}

const buttonbits = [_]u8{ 0, 1, 4, 5, 2, 3, 6, 7, 0, 1, 2, 3, 2, 3, 6, 7 };

var ps2: struct {
    msg: [4]i16 = @splat(0),
    nb: i32 = 0,
} = .{};

///  ps/2 mouse message is three bytes
///
///     byte 0 -        0 0 SDY SDX 1 M R L
///     byte 1 -        DX
///     byte 2 -        DY
///
///  shift & right button is the same as middle button
///
/// Intellimouse and AccuPoint with extra buttons deliver
///     byte 3 -        00 or 01 or FF according to extra button state.
/// extra buttons are mapped in this code to buttons 4 and 5.
/// AccuPoint generates repeated events for these buttons;
///  it and Intellimouse generate 'down' events only, so
/// user-level code is required to generate button 'up' events
/// if they are needed by the application.
/// Also on laptops with AccuPoint AND external mouse, the
/// controller may deliver 3 or 4 bytes according to the type
/// of the external mouse; code must adapt.
///
/// On the NEC Versa series (and perhaps others?) we seem to
/// lose a byte from the packet every once in a while, which
/// means we lose where we are in the instruction stream.
/// To resynchronize, if we get a byte more than two seconds
/// after the previous byte, we assume it's the first in a packet.
fn ps2mouseputc(c: i32, shift: i32) void {
    const msg = &ps2.msg;

    //
    // Resynchronize in stream with timing; see comment above.
    //
    if (lastmousems() > 2000)
        ps2.nb = 0;

    //
    //  check byte 0 for consistency
    //
    if (ps2.nb == 0 and (c & 0xc8) != 0x08) {
        if (intellimouse and (c == 0x00 or c == 0x01 or c == 0xFF)) {
            // last byte of 4-byte packet
            packetsize = 4;
        }
        return;
    }

    // DIFF: `synaptic` sets packetsize to 6 a moment before it replaces
    // this function; a byte arriving in between must not run past msg
    // (the C writes beyond its array then).
    if (ps2.nb >= msg.len)
        ps2.nb = 0;
    msg[@intCast(ps2.nb)] = @truncate(c);
    ps2.nb += 1;
    if (ps2.nb >= packetsize) {
        ps2.nb = 0;
        if (msg[0] & 0x10 != 0)
            msg[1] = signext(msg[1]);
        if (msg[0] & 0x20 != 0)
            msg[2] = signext(msg[2]);

        var buttons: i32 = buttonbits[@intCast((msg[0] & 7) | @as(i16, if (shift != 0) 8 else 0))];
        if (intellimouse and packetsize == 4) {
            if ((msg[3] & 0xc8) == 0x08) {
                // first byte of 3-byte packet
                packetsize = 3;
                msg[0] = msg[3];
                ps2.nb = 1;
                // fall through to emit previous packet
            } else {
                // The AccuPoint on the Toshiba 34[48]0CT
                // encodes extra buttons as 4 and 5. They repeat
                // and don't release, however, so user-level
                // timing code is required. Furthermore,
                // intellimice with 3buttons + scroll give a
                // two's complement number in the lower 4 bits
                // (bit 4 is sign extension) that describes
                // the amount the scroll wheel has moved during
                // the last sample. Here we use only the sign to
                // decide whether the wheel is moving up or down
                // and generate a single button 4 or 5 click
                // accordingly.
                if ((msg[3] >> 3) & 1 != 0)
                    buttons |= 1 << 3
                else if (msg[3] & 0x7 != 0)
                    buttons |= 1 << 4;
            }
        }
        const dx: i32 = msg[1];
        const dy: i32 = -@as(i32, msg[2]);
        mousetrack(dx, dy, buttons, now());
    }
}

fn diffpos(x1: i32, y1: i32, x2: i32, y2: i32) u32 {
    const dx: u32 = @abs(x1 -% x2);
    const dy: u32 = @abs(y1 -% y2);
    return dx *% dx +% dy *% dy;
}

var syn: struct {
    msg: [6]i16 = @splat(0),
    nb: i32 = 0,
    prevx: i32 = 0,
    prevy: i32 = 0,
    maxx: i32 = 0,
    minx: i32 = 6143,
    maxy: i32 = 0,
    miny: i32 = 6143,
    edgminx: i32 = 1632,
    edgmaxx: i32 = 5312,
    edgminy: i32 = 1568,
    edgmaxy: i32 = 4288,
    ignore: i32 = 0,
    press: usize = 0,
} = .{};

fn synmouseputc(c: i32, shift: i32) void {
    const s = &syn;
    const msg = &s.msg;

    const deltah = 58;
    const deltal = 3;
    const click = [4]i32{ Mousereleas, Mouseleft, Mousemid, Mouseright };

    // re-synchronize with stream in case
    // of packet loss
    if (lastmousems() > 500 and s.nb != 0)
        s.nb = 0;

    // ignore 3-6 bytes
    // of trailing idle packet
    if (s.nb == 2 and (c & 0xFF) == 0x0 and msg[0] == 0x80)
        s.ignore = 4;

    if (s.ignore != 0) {
        s.ignore -= 1;
        s.nb += 1;
        if (s.nb == packetsize)
            s.nb = 0;
        return;
    }

    msg[@intCast(s.nb)] = @intCast(c & 0xff);

    s.nb += 1;
    if (s.nb < packetsize)
        return;

    s.nb = 0;

    var w: i32 = (msg[3] & 0x4) >> 2;
    w |= (msg[0] & 0x4) >> 1;
    w |= (msg[0] & 0x30) >> 2;

    const z: i32 = msg[2];

    // handle trackpoint
    if (w == 3) {
        // handle buttons
        if (msg[0] == 0x84 and msg[3] == 0xc4) {
            switch (msg[1]) {
                Mousereleas => s.press = 0,
                Mouseleft => s.press = 1,
                Mousemid => s.press = 2,
                Mouseright => s.press = 3,
                else => {},
            }
        }

        const buttons: i32 = buttonbits[@intCast((msg[1] & 7) | @as(i16, if (shift != 0) 8 else 0))];
        if (msg[1] & 0x10 != 0)
            msg[4] = signext(msg[4]);
        if (msg[1] & 0x20 != 0)
            msg[5] = signext(msg[5]);
        const dx: i32 = msg[4];
        const dy: i32 = -@as(i32, msg[5]);
        mousetrack(dx, dy, buttons, now());
        return;
    }

    // palm-detect
    if (w >= 6 or z > 110 or z < 40)
        return;

    if (w < 4 and w != 2)
        return;

    // handle touchpad
    if (@atomicLoad(bool, &disabletouch, .monotonic))
        return;

    var x: i32 = msg[4];
    x |= @as(i32, msg[1] & 0xF) << 8;
    if (msg[3] & 0x10 != 0)
        x |= (1 << 12);

    var y: i32 = msg[5];
    y |= @as(i32, msg[1] & 0xF0) << 4;
    if (msg[3] & 0x20 != 0)
        y |= (1 << 12);

    // compute edges
    if (x > s.maxx)
        s.maxx = x;
    if (y > s.maxy)
        s.maxy = y;
    if (x < s.minx)
        s.minx = x;
    if (y < s.miny)
        s.miny = y;

    // compute margins
    s.edgminx = @divTrunc(s.minx * 57, 50);
    s.edgmaxx = @divTrunc(s.maxx * 121, 125);
    s.edgminy = @divTrunc(s.miny * 57, 50);
    s.edgmaxy = @divTrunc(s.maxy * 121, 125);

    if (x < s.edgminx or x > s.edgmaxx)
        return;

    if (y < s.edgminy or y > s.edgmaxy)
        return;

    const i = screen.gscreen orelse return;

    // DIFF: the C divides by zero here (a trap in the interrupt
    // handler) if the two margins of an axis ever coincide.
    if (s.edgmaxx == s.edgminx or s.edgmaxy == s.edgminy)
        return;

    x = @divTrunc((x - s.edgminx) * Dx(i.clipr), s.edgmaxx - s.edgminx);
    if (x < 0)
        x = 0;
    const t = Dy(i.clipr) - @divTrunc(s.edgminy * -Dy(i.clipr), s.edgmaxy - s.edgminy);
    y = t + @divTrunc(y * -Dy(i.clipr), s.edgmaxy - s.edgminy);
    if (y < 0)
        y = 0;

    // ignore accidental taps
    const dp = diffpos(x, y, s.prevx, s.prevy);
    if (dp > deltah * deltah or dp < deltal * deltal) {
        s.prevx = x;
        s.prevy = y;
        return;
    }

    // imitate trackpoint buttons
    const buttons: i32 = buttonbits[@intCast((click[s.press] & 7) | @as(i32, if (shift != 0) 8 else 0))];
    mousetrack(x - s.prevx, y - s.prevy, buttons, now());
    s.prevx = x;
    s.prevy = y;
}

///  set up a ps2 mouse
fn ps2mouse() Error!void {
    if (mousetype == MousePS2)
        return;

    mousetype = MousePS2;
    packetsize = 3;
    mousehwaccel = false;

    try i8042auxenable(ps2mouseputc);
    _ = i8042auxcmd(0xEA); // set stream mode
}

/// The PS/2 Trackpoint multiplexor on the IBM Thinkpad T23 ignores
/// acceleration commands.  It is supposed to pass them on
/// to the attached device, but my Logitech mouse is simply
/// not behaving any differently.  For such devices, we allow
/// the user to use "hwaccel off" to tell us to back off to
/// software acceleration even if we're using the PS/2 port.
/// (Serial mice are always software accelerated.)
/// For more information on the Thinkpad multiplexor, see
/// http://wwwcssrv.almaden.ibm.com/trackpoint/
fn setaccelerated(x: i32) void {
    accelerated = x;
    if (mousehwaccel) {
        switch (mousetype) {
            MousePS2 => {
                _ = i8042auxcmd(0xE7);
                return;
            },
            else => {},
        }
    }
    mouseaccelerate(x);
}

fn setlinear() void {
    accelerated = 0;
    if (mousehwaccel) {
        switch (mousetype) {
            MousePS2 => {
                _ = i8042auxcmd(0xE6);
                return;
            },
            else => {},
        }
    }
    mouseaccelerate(0);
}

fn setres(n: i32) void {
    resolution = n;
    switch (mousetype) {
        MousePS2 => {
            _ = i8042auxcmd(0xE8);
            _ = i8042auxcmd(n);
        },
        else => {},
    }
}

fn setintellimouse() void {
    intellimouse = true;
    packetsize = 4;
    switch (mousetype) {
        MousePS2 => {
            _ = i8042auxcmd(0xF3); // set sample
            _ = i8042auxcmd(0xC8);
            _ = i8042auxcmd(0xF3); // set sample
            _ = i8042auxcmd(0x64);
            _ = i8042auxcmd(0xF3); // set sample
            _ = i8042auxcmd(0x50);
        },
        // DIFF: no Mouseserial
        else => {},
    }
}

fn resetmouse() void {
    packetsize = 3;
    switch (mousetype) {
        MousePS2 => {
            _ = i8042auxcmd(0xF6);
            _ = i8042auxcmd(0xEA); // streaming
            _ = i8042auxcmd(0xE8); // set resolution
            _ = i8042auxcmd(3);
        },
        else => {},
    }
}

fn setstream(on: bool) Error!void {
    switch (mousetype) {
        MousePS2 => {
            //
            // disabling streaming can fail when
            // a packet is currently transmitted.
            //
            for (0..4) |_| {
                if (i8042auxcmd(if (on) 0xF4 else 0xF5) != -1)
                    break;
                try proc.tsleep(&dat.up().?.sleep, proc.return0, null, 50);
            }
        },
        else => {},
    }
}

fn disstream() Error!void {
    for (0..4) |_| {
        if (i8042auxcmd(0xF5) != -1)
            break;
        try proc.tsleep(&dat.up().?.sleep, proc.return0, null, 50);
    }
}

fn setabs() Error!void {
    try disstream();

    _ = i8042auxcmd(0xE8);
    _ = i8042auxcmd(2);
    _ = i8042auxcmd(0xE8);
    _ = i8042auxcmd(0);
    _ = i8042auxcmd(0xE8);
    _ = i8042auxcmd(0);
    _ = i8042auxcmd(0xE8);
    _ = i8042auxcmd(1);
    _ = i8042auxcmd(0xF3);
    _ = i8042auxcmd(0x14);
}

pub fn mousectl(cb: *Cmdbuf) Error!void {
    ql.qlock(&mousectlqlock);
    defer ql.qunlock(&mousectlqlock);

    const ct = try parse.lookupcmd(cb, &mousectlmsg);
    switch (ct.index) {
        CMaccelerated => {
            try setstream(false);
            setaccelerated(if (cb.nf == 1) 1 else atoi(cb.f[1]));
            try setstream(true);
        },
        CMintellimouse => {
            try setstream(false);
            setintellimouse();
            try setstream(true);
        },
        CMlinear => {
            try setstream(false);
            setlinear();
            try setstream(true);
        },
        CMps2 => {
            intellimouse = false;
            try ps2mouse();
            try setstream(true);
        },
        CMsynaptic => {
            intellimouse = false;
            try setabs();
            synaptic = true;
            packetsize = 6;
            mousehwaccel = false;
            try i8042auxenable(synmouseputc);
            _ = i8042auxcmd(0xF3);
            _ = i8042auxcmd(0xC8);
            _ = i8042auxcmd(0xF3);
            _ = i8042auxcmd(0x64);
            _ = i8042auxcmd(0xF3);
            _ = i8042auxcmd(0x50);
            _ = i8042auxcmd(0xF4);
        },
        CMps2intellimouse => {
            try ps2mouse();
            setintellimouse();
            try setstream(true);
        },
        CMres => {
            try setstream(false);
            if (cb.nf >= 2)
                setres(atoi(cb.f[1]))
            else
                setres(1);
            try setstream(true);
        },
        CMreset => {
            resetmouse();
            if (accelerated != 0)
                setaccelerated(accelerated);
            if (resolution != 0)
                setres(resolution);
            if (intellimouse)
                setintellimouse();
            try setstream(true);
        },
        // DIFF: no CMserial
        CMhwaccel => {
            if (std.mem.eql(u8, cb.f[1], "on"))
                mousehwaccel = true
            else if (std.mem.eql(u8, cb.f[1], "off"))
                mousehwaccel = false
            else
                return parse.cmderror(cb, "bad mouse control message");
        },
        CMtouchpad => {
            if (std.mem.eql(u8, cb.f[1], "off")) {
                if (synaptic)
                    @atomicStore(bool, &disabletouch, true, .monotonic);
            } else if (std.mem.eql(u8, cb.f[1], "on")) {
                if (synaptic)
                    @atomicStore(bool, &disabletouch, false, .monotonic);
            } else return parse.cmderror(cb, "bad mouse control message");
        },
        else => {},
    }
}
