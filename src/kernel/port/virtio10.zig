//! What the virtio 1.0 drivers share: register layout, the ring
//! structures, and access to a device's registers.
//! from 9/port/virtio10.h and 9/port/virtio10mem.c
//!
//! DIFF: registers are in memory only.  The C has a second version for
//! the PC (pc/virtio10pc.c) that also handles registers in I/O port
//! space, so a Vio there is either; devices of the 2011 baseline's era
//! and QEMU's put the virtio 1.0 registers in a memory BAR.

const arch = @import("../arch.zig");
const pci = @import("pci.zig");

// §2.1 Device Status Field
pub const Sacknowledge = 1;
pub const Sdriver = 2;
pub const Sdriverok = 4;
pub const Sfeaturesok = 8;
pub const Sfailed = 128;

// feat[1] bits
pub const Fversion1 = 1 << (32 - 32);

pub const Vconf_devfeatsel = 0;
pub const Vconf_devfeat = 4;
pub const Vconf_drvfeatsel = 8;
pub const Vconf_drvfeat = 12;
pub const Vconf_msixcfg = 16;
pub const Vconf_nqueues = 18;
pub const Vconf_status = 20;
pub const Vconf_cfggen = 21;
pub const Vconf_queuesel = 22;
pub const Vconf_queuesize = 24;
pub const Vconf_queuemsixvect = 26;
pub const Vconf_queueenable = 28;
pub const Vconf_queuenotifyoff = 30;
pub const Vconf_queuedesc = 32;
pub const Vconf_queueavail = 40;
pub const Vconf_queueused = 48;
pub const Vconf_sz = 56;

/// A mapped block of a device's registers.
pub const Vio = struct {
    mem: [*]u8 = undefined,
};

pub const Vring = extern struct {
    flags: u16,
    idx: u16,
};

pub const Vdesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const Vused = extern struct {
    id: u32,
    len: u32,
};

fn reg(comptime T: type, r: *const Vio, p: usize) *align(1) volatile T {
    return @ptrCast(r.mem + p);
}

pub fn vin8(r: *const Vio, p: usize) u8 {
    return reg(u8, r, p).*;
}

pub fn vin16(r: *const Vio, p: usize) u16 {
    return reg(u16, r, p).*;
}

pub fn vin32(r: *const Vio, p: usize) u32 {
    return reg(u32, r, p).*;
}

pub fn vin64(r: *const Vio, p: usize) u64 {
    // DIFF: two 32-bit reads; a device need not support wider ones.
    return @as(u64, vin32(r, p)) | @as(u64, vin32(r, p + 4)) << 32;
}

pub fn vout8(r: *const Vio, p: usize, v: u8) void {
    reg(u8, r, p).* = v;
}

pub fn vout16(r: *const Vio, p: usize, v: u16) void {
    reg(u16, r, p).* = v;
}

pub fn vout32(r: *const Vio, p: usize, v: u32) void {
    reg(u32, r, p).* = v;
}

pub fn vout64(r: *const Vio, p: usize, v: u64) void {
    vout32(r, p, @truncate(v));
    vout32(r, p + 4, @truncate(v >> 32));
}

pub fn virtiounmap(r: *Vio, sz: usize) void {
    arch.vunmap(@intFromPtr(r.mem), sz);
}

/// Map the registers that the vendor capability at `cap` describes; at
/// least `size` bytes of them, or all if size is 0.
pub fn virtiomapregs(p: *pci.Pcidev, cap: i32, size_: usize, v: *Vio) ?*Vio {
    if (cap < 0)
        return null;
    const bar = @as(usize, @intCast(pci.pcicfgr8(p, cap + 4))) % p.mem.len;
    var addr: u64 = pci.pcicfgr32(p, cap + 8);
    const len: u64 = pci.pcicfgr32(p, cap + 12);
    var size = size_;
    if (size == 0)
        size = len
    else if (len < size)
        return null;
    if (p.mem[bar].bar & 1 != 0 or p.mem[bar].size <= 0 or addr + len > @as(u64, @intCast(p.mem[bar].size)))
        return null;

    addr += p.mem[bar].bar & ~@as(u64, 0xF);
    v.mem = @ptrFromInt(arch.vmap(addr, size) orelse return null);
    return v;
}
