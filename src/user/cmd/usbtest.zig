//! usbtest - the test of the USB programs' library (src/user/lib/usb,
//! from nusb/lib): what the library makes of a device, printed.
//! tools/usbtest.c is the same with 9front's library, built in the
//! guest; tools/usbzig.rc runs both on the devices of usbfake and
//! compares what they print.
//!
//! usage: usbtest [ devid ... ]
//!        usbtest -r file op ...
//! With no device it prints the names of the classes.
//!
//! -r is no part of the twin: it opens file for reading and writing
//! and does each op on it in turn, w:hex (write those bytes) or r:n
//! (read up to n), and prints what each gave.  It is how the script
//! talks to the raw file of a disk, where a command, its data and its
//! status follow each other on one file descriptor.

const std = @import("std");
const libc = @import("libc");
const usb = @import("usb");
const sys = libc.sys;

const print = libc.print;

fn code(r: anytype) i32 {
    _ = r catch return -1;
    return 0;
}

fn raw(file: []const u8, ops: []const []const u8) noreturn {
    const big = libc.allocator.alloc(u8, 65536) catch libc.sysfatal("malloc", .{});
    const fd = libc.open(file, sys.ORDWR) catch {
        print("open: %r\n", .{});
        libc.exits("open");
    };
    for (ops) |op| {
        if (op.len < 2 or op[1] != ':')
            libc.sysfatal("bad op %s", .{op});
        if (op[0] == 'w') {
            const h = op[2..];
            const n = h.len / 2;
            for (0..n) |i|
                big[i] = @truncate(libc.strtoul(h[2 * i ..][0..2], 16).v);
            if (libc.write(fd, big[0..n])) |w|
                print("write %d: %d\n", .{ n, w })
            else |_|
                print("write %d: %r\n", .{n});
        } else {
            const n: usize = @intCast(@min(libc.strtoul(op[2..], 10).v, big.len));
            if (libc.read(fd, big[0..n])) |r| {
                var sum: u32 = 0;
                for (big[0..r]) |c|
                    sum = sum *% 31 +% c;
                print("read %d: %d sum %ud %H\n", .{ n, r, sum, usb.Hex{ .b = big[0..@min(r, 40)] } });
            } else |_| print("read %d: %r\n", .{n});
        }
    }
    libc.exits(null);
}

pub fn main(argv: []const []const u8) void {
    var buf: [8]u8 = undefined;
    var cb: [12]u8 = undefined;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'd' => usb.usbdebug += 1,
        'r' => {
            const file = args.value() orelse libc.sysfatal("usage", .{});
            raw(file, args.rest());
        },
        else => {},
    };
    const rest = args.rest();
    if (rest.len == 0) {
        var i: u32 = 0;
        while (i < 256) : (i += 1)
            print("%d %s\n", .{ i, usb.classname(i, &cb) });
        libc.exits(null);
    }
    for (rest) |arg| {
        const d = usb.getdev(arg) orelse {
            print("%s: getdev: %r\n", .{arg});
            continue;
        };
        const ud = d.usb.?;
        print("%s: dir %s id %d hname %s usb3 %d maxpkt %d depth %d\n", .{ arg, d.dir, d.id, d.hname, @intFromBool(d.isusb3), d.maxpkt, d.depth });
        print("ver %x csp %ux vid %x did %x dno %x class %d nconf %d sid %d %d %d\n", .{
            ud.ver,  ud.csp,  ud.vid,  ud.did, ud.dno, ud.class, ud.nconf,
            ud.vsid, ud.psid, ud.ssid,
        });
        print("%U", .{usb.U{ .d = d }});
        for (ud.ep, 0..) |first, i| {
            var epp = first;
            while (epp) |ep| : (epp = ep.next)
                print("ep[%d] id %d dir %d type %d attrib %x pollival %d maxpkt %d ntds %d conf %d iface %d alt %d\n", .{
                    i,                                           ep.id,   ep.dir, ep.type, ep.attrib, ep.pollival,
                    ep.maxpkt,                                   ep.ntds,
                    if (ep.conf) |c| c.cval else -1,
                    if (ep.iface) |f| f.id else -1,
                    if (ep.iface) |f| f.alt else -1,
                });
        }
        for (ud.ddesc, 0..) |slot, i| {
            const dd = slot orelse break;
            print("ddesc %d conf %d iface %d ep %d: %H\n", .{
                i,                                dd.conf.?.cval,
                if (dd.iface) |f| f.id else -1,
                if (dd.ep) |e| e.id else -1,
                usb.Hex{ .b = dd.data },
            });
        }

        for ([_]i32{ 2, 0, 99 }) |sid| {
            const s = usb.loaddevstr(d, sid);
            print("string %d: %s\n", .{ sid, s });
            libc.allocator.free(s);
        }

        for (ud.ep[1..]) |slot| {
            const ep = slot orelse continue;
            const epd = usb.openep(d, ep) orelse {
                print("openep %d: %r\n", .{ep.id});
                continue;
            };
            print("openep %d: dir %s id %d maxpkt %d\n", .{ ep.id, epd.dir, epd.id, epd.maxpkt });
            var mode: u32 = sys.ORDWR;
            if (ep.dir == usb.Ein)
                mode = sys.OREAD;
            if (ep.dir == usb.Eout)
                mode = sys.OWRITE;
            print("opendevdata %d\n", .{@intFromBool(if (usb.opendevdata(epd, mode)) |_| true else |_| false)});
            print("unstall %d\n", .{code(usb.unstall(d, epd, ep.dir))});
            print("%U", .{usb.U{ .d = epd }});
            // it is there now, and is opened
            const epd2 = usb.openep(d, ep);
            print("again %d\n", .{@intFromBool(epd2 != null)});
            usb.closedev(epd2);
            usb.closedev(epd);
        }
        if (ud.conf[0]) |c| {
            usb.setconf(d, c);
            print("setconf %d\n", .{0});
            for (c.iface) |first| {
                var ip = first;
                while (ip) |ifc| : (ip = ifc.next)
                    print("setalt %d %d: %d\n", .{ ifc.id, ifc.alt, code(usb.setalt(d, ifc)) });
            }
        }
        if (usb.devctl(d, "name %s%d", .{ "x", 7 })) |n|
            print("devctl %d\n", .{n})
        else |_|
            print("devctl %d\n", .{-1});
        libc.werrstr("none", .{});
        if (usb.usbcmd(d, usb.Rd2h | usb.Rvendor | usb.Rdev, 0x55, 1, 2, buf[0..4])) |n|
            print("usbcmd %d: %r\n", .{n})
        else |_|
            print("usbcmd %d: %r\n", .{-1});
        usb.closedev(d);
    }
    libc.exits(null);
}
