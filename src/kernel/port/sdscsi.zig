//! The generic SCSI command layer for storage drivers whose devices
//! speak SCSI (virtio-scsi, ATAPI through AHCI, USB mass storage ...):
//! a driver supplies SDifc.rio and uses scsiverify, scsionline and
//! scsibio as its verify, online and bio.
//! from 9/port/sdscsi.c
//!
//! DIFF:
//!   - scsibio returns a Zig error where the C calls error(); its other
//!     failures are still the result -1, which devsd turns into Eio.
//!     Its data is a slice, as SDifc.bio has it, and its SDreq is freed
//!     by a defer.
//!   - scsiverify frees its inquiry buffer when the INQUIRY command
//!     fails; the C leaks it.
//!   - The "wait a little, uninterruptibly" of scsirio is a loop around
//!     tsleep where the C has `while(waserror());`.
//!   - A driver using this layer must supply rio; the calls go through
//!     `.?`, as the C calls through the pointer unchecked.

const std = @import("std");
const arch = @import("../arch.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const sd = @import("devsd.zig");
const p9 = @import("print.zig");

const print = p9.print;

pub const Error = proc.Error;
const SDreq = sd.SDreq;
const SDunit = sd.SDunit;
const SDok = sd.SDok;
const SDcheck = sd.SDcheck;
const SDbusy = sd.SDbusy;
const SDvalidsense = sd.SDvalidsense;
const sdmalloc = sd.sdmalloc;
const sdfree = sd.sdfree;

fn scsitest(r: *SDreq) i32 {
    r.write = false;
    @memset(&r.cmd, 0);
    r.cmd[1] = @truncate(r.lun << 5);
    r.clen = 6;
    r.data = null;
    r.dlen = 0;
    r.flags = 0;

    r.status = ~@as(i32, 0);

    return r.unit.dev.ifc.rio.?(r);
}

pub fn scsiverify(unit: *SDunit) i32 {
    const r = alloc.new(SDreq) orelse return 0;
    defer alloc.free(r);
    const inquiry = sdmalloc(unit.inquiry.len) orelse return 0;
    r.* = .{ .unit = unit };
    r.lun = 0; // ???

    @memset(&unit.inquiry, 0);
    r.write = false;
    r.cmd[0] = 0x12;
    r.cmd[1] = @truncate(r.lun << 5);
    r.cmd[4] = 36;
    r.clen = 6;
    r.data = inquiry;
    r.dlen = 36;
    r.flags = 0;

    r.status = ~@as(i32, 0);
    if (unit.dev.ifc.rio.?(r) != SDok) {
        sdfree(inquiry); // DIFF: leaked in the C
        return 0;
    }
    @memcpy(unit.inquiry[0..r.dlen], inquiry[0..r.dlen]);
    sdfree(inquiry);

    var status: i32 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        while (true) {
            status = scsitest(r);
            if (status != SDbusy)
                break;
        }
        if (status == SDok or status != SDcheck)
            break;
        if (r.flags & SDvalidsense == 0)
            break;
        if ((r.sense[2] & 0x0F) != 0x02)
            continue;

        // Unit is 'not ready'.
        // If it is in the process of becoming ready or needs
        // an initialising command, set status so it will be spun-up
        // below.
        // If there's no medium, that's OK too, but don't
        // try to spin it up.
        if (r.sense[12] == 0x04) {
            if (r.sense[13] == 0x02 or r.sense[13] == 0x01) {
                status = SDok;
                break;
            }
        }
        if (r.sense[12] == 0x3A)
            break;
    }

    if (status == SDok) {
        // Try to ensure a direct-access device is spinning.
        // Don't wait for completion, ignore the result.
        if ((unit.inquiry[0] & 0x1F) == 0) {
            @memset(&r.cmd, 0);
            r.write = false;
            r.cmd[0] = 0x1B;
            r.cmd[1] = @truncate((r.lun << 5) | 0x01);
            r.cmd[4] = 1;
            r.clen = 6;
            r.data = null;
            r.dlen = 0;
            r.flags = 0;

            r.status = ~@as(i32, 0);
            _ = unit.dev.ifc.rio.?(r);
        }
    }

    if (status == SDok or status == SDcheck)
        return 1;
    return 0;
}

fn scsirio(r: *SDreq) i32 {
    // Perform an I/O request, returning
    //   -1  failure
    //    0  ok
    //    1  no medium present
    //    2  retry
    // The contents of r may be altered so the
    // caller should re-initialise if necesary.
    r.status = ~@as(i32, 0);
    switch (r.unit.dev.ifc.rio.?(r)) {
        else => {},
        SDcheck => sense: {
            if (r.flags & SDvalidsense == 0)
                break :sense;
            switch (r.sense[2] & 0x0F) {
                0x00, // no sense
                0x01, // recovered error
                => return 2,
                0x06 => { // check condition
                    // 0x28 - not ready to ready transition,
                    //        medium may have changed.
                    // 0x29 - power on or some type of reset.
                    if (r.sense[12] == 0x28 and r.sense[13] == 0)
                        return 2;
                    if (r.sense[12] == 0x29)
                        return 2;
                },
                0x02 => { // not ready
                    // If no medium present, bail out.
                    // If unit is becoming ready, rather than not
                    // not ready, wait a little then poke it again.
                    if (r.sense[12] == 0x3A)
                        break :sense;
                    if (r.sense[12] != 0x04 or r.sense[13] != 0x01)
                        break :sense;

                    // DIFF: while(waserror()); tsleep(...); poperror();
                    // an interrupted sleep starts over.
                    while (true) {
                        proc.tsleep(&arch.up().?.sleep, proc.return0, null, 500) catch continue;
                        break;
                    }
                    _ = scsitest(r);
                    return 2;
                },
                else => {},
            }
        },
        SDok => return 0,
    }
    return -1;
}

fn cap10(r: *SDreq) void {
    r.cmd[0] = 0x25;
    r.cmd[1] = @truncate(r.lun << 5);
    r.clen = 10;
    r.dlen = 8;
}

fn cap16(r: *SDreq) void {
    const i: u32 = 32;
    r.cmd[0] = 0x9e;
    r.cmd[1] = 0x10;
    r.cmd[10] = @truncate(i >> 24);
    r.cmd[11] = @truncate(i >> 16);
    r.cmd[12] = @truncate(i >> 8);
    r.cmd[13] = @truncate(i);
    r.clen = 16;
    r.dlen = i;
}

fn belong(u: [*]const u8) u32 {
    return @as(u32, u[0]) << 24 | @as(u32, u[1]) << 16 | @as(u32, u[2]) << 8 | u[3];
}

fn capreply(r: *SDreq, secsize: ?*u32) u64 {
    var ss: u32 = undefined;
    var s: u64 = undefined;

    const u = r.data.?;
    if (r.clen == 16) {
        s = @as(u64, belong(u)) << 32 | belong(u + 4);
        ss = belong(u + 8);
    } else {
        s = belong(u);
        ss = belong(u + 4);
    }
    if (secsize) |p|
        p.* = ss;
    return s;
}

pub fn scsionline(unit: *SDunit) i32 {
    const r = alloc.new(SDreq) orelse return 0;
    defer alloc.free(r);
    const p = sdmalloc(32) orelse return 0;
    defer sdfree(p);

    var ok: i32 = 0;
    var cap: *const fn (*SDreq) void = &cap10;
    r.* = .{ .unit = unit };
    r.lun = 0; // ???
    var retries: i32 = 0;
    while (retries < 10) : (retries += 1) {
        // Read-capacity is mandatory for DA, WORM, CD-ROM and
        // MO. It may return 'not ready' if type DA is not
        // spun up, type MO or type CD-ROM are not loaded or just
        // plain slow getting their act together after a reset.
        r.write = false;
        r.data = p;
        r.flags = 0;
        @memset(&r.cmd, 0);
        cap(r);

        switch (scsirio(r)) {
            else => {
                // ATAPI returns error and no sense information
                // on media change / no media present.
                // count as retries.
                if (retries < 4)
                    continue;
            },
            0 => {
                var ss: u32 = undefined;
                var s = capreply(r, &ss);
                if (s == 0xffffffff and cap == &cap10) {
                    cap = &cap16;
                    continue;
                }
                if (s == 0xffffffffffffffff)
                    s = 0;

                // Some ATAPI CD readers lie about the block size.
                // Since we don't read audio via this interface
                // it's okay to always fudge this.
                if (ss == 2352)
                    ss = 2048;

                // Devices with removable media may return 0 sectors
                // when they have empty media (e.g. sata dvd writers);
                // if so, keep the count zero.
                //
                // Read-capacity returns the LBA of the last sector,
                // therefore the number of sectors must be incremented.
                if (s != 0)
                    s += 1;

                ok = if (unit.sectors != s) 2 else 1;
                unit.sectors = s;
                unit.secsize = ss;
            },
            1 => {
                ok = if (unit.sectors != 0) 2 else 1;
                unit.sectors = 0;
            },
            2 => continue,
        }
        break;
    }

    // print("scsionline: %s: ok=%d retries=%d sectors=%llud secsize=%lud\n",
    //     unit->name, ok, retries, unit->sectors, unit->secsize);

    if (ok != 0)
        return ok + retries
    else
        return 0;
}

fn scsifmt10(r: *SDreq, write: bool, lun: u32, nb: u32, bno: u64) void {
    const c = &r.cmd;
    if (!write)
        c[0] = 0x28
    else
        c[0] = 0x2A;
    c[1] = @truncate(lun << 5);
    c[2] = @truncate(bno >> 24);
    c[3] = @truncate(bno >> 16);
    c[4] = @truncate(bno >> 8);
    c[5] = @truncate(bno);
    c[6] = 0;
    c[7] = @truncate(nb >> 8);
    c[8] = @truncate(nb);
    c[9] = 0;

    r.clen = 10;
}

fn scsifmt16(r: *SDreq, write: bool, lun: u32, nb: u32, bno: u64) void {
    const c = &r.cmd;
    if (!write)
        c[0] = 0x88
    else
        c[0] = 0x8A;
    c[1] = @truncate(lun << 5); // so wrong
    c[2] = @truncate(bno >> 56);
    c[3] = @truncate(bno >> 48);
    c[4] = @truncate(bno >> 40);
    c[5] = @truncate(bno >> 32);
    c[6] = @truncate(bno >> 24);
    c[7] = @truncate(bno >> 16);
    c[8] = @truncate(bno >> 8);
    c[9] = @truncate(bno);
    c[10] = @truncate(nb >> 24);
    c[11] = @truncate(nb >> 16);
    c[12] = @truncate(nb >> 8);
    c[13] = @truncate(nb);
    c[14] = 0;
    c[15] = 0;

    r.clen = 16;
}

/// data.len is nb*unit.secsize.  Returns the number of bytes
/// transferred or -1.
pub fn scsibio(unit: *SDunit, lun: u32, write: bool, data: []u8, nb: usize, bno: u64) Error!isize {
    const r = alloc.snew(SDreq);
    defer alloc.free(r);
    r.* = .{ .unit = unit };
    r.lun = lun;
    again: while (true) {
        r.write = write;
        if (bno > 0xffffffff)
            scsifmt16(r, write, lun, @truncate(nb), bno)
        else
            scsifmt10(r, write, lun, @truncate(nb), bno);
        r.data = data.ptr;
        r.dlen = nb * unit.secsize;
        r.flags = 0;

        r.status = ~@as(i32, 0);
        const st = scsirio(r);
        if (st != 0 and st != 2)
            return -1;
        if (st == 0) {
            // scsi allows commands to return successfully
            // but return sense data, indicating that the
            // operation didn't proceed as expected.
            // (confusing, no).  this allows the raw commands
            // to successfully return errors.  but any sense
            // data bio sees must be an error.  bomb out.
            if (r.status == SDok and r.rlen > 0 and
                ((r.flags & SDvalidsense) == 0 or r.sense[2] == 0))
                return @intCast(r.rlen);
        }
        // case 2, and case 0 falling through
        if (r.flags & SDvalidsense == 0)
            return -1;
        switch (r.sense[2] & 0x0F) {
            else => {},
            0x01 => // recovered error
            print("%s: recovered error at sector %llud\n", .{ unit.perm.name, bno }),
            0x06 => { // check condition
                // Check for a removeable media change.
                // If so, mark it by zapping the geometry info
                // to force an online request.
                if (r.sense[12] == 0x28 and r.sense[13] == 0) {
                    if (unit.inquiry[1] & 0x80 != 0)
                        unit.sectors = 0;
                }
            },
            0x02 => { // not ready
                // If unit is becoming ready,
                // rather than not not ready, try again.
                if (r.sense[12] == 0x04 and r.sense[13] == 0x01)
                    continue :again;
            },
        }
        return proc.errorf("%s %.2ux%.2ux%.2ux %lld", .{
            proc.errtext(error.Eio), r.sense[2],              r.sense[12],
            r.sense[13],             @as(i64, @bitCast(bno)),
        });
    }
}
