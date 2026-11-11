//! The PCI side of the xHCI driver: find the controllers, take them
//! from the firmware and hand them to usbxhci.zig.
//! from 9/port/usbxhcipci.c
//!
//! DIFF:
//!   - hp->irq is the interrupt line of the PCI configuration as in the
//!     C, but it is not what delivers interrupts: intrenable (called by
//!     xhciinit) takes the tbdf and programs MSI or MSI-X.
//!   - init returns an error where the C raises one.
//!   - The registers are mapped with arch.vmap, which returns an
//!     address or null.

const arch = @import("../arch.zig");
const pci = @import("pci.zig");
const proc = @import("proc.zig");
const usb = @import("usb.zig");
const devusb = @import("devusb.zig");
const usbxhci = @import("usbxhci.zig");
const p9 = @import("print.zig");

const print = p9.print;

const Error = proc.Error;
const Pcidev = pci.Pcidev;
const Hci = usb.Hci;
const Nhcis = usb.Nhcis;
const Xhci = usbxhci.Xhci;

var ctlrs: [Nhcis]?*Xhci = @splat(null);

fn pciwaddr(va: usize) u64 {
    return arch.paddr(va);
}

var already = false;

fn scanpci() void {
    if (already)
        return;
    already = true;
    var pp: ?*Pcidev = null;
    while (true) {
        pp = pci.pcimatch(pp, 0, 0);
        const p = pp orelse break;
        // Find XHCI controllers (Programming Interface = 0x30).
        if (p.ccrb != pci.Pcibcserial or p.ccru != pci.Pciscusb or p.ccrp != 0x30)
            continue;
        if (p.mem[0].bar & 1 != 0)
            continue;
        const iosize: u64 = @intCast(p.mem[0].size);
        if (iosize == 0)
            continue;
        const io = p.mem[0].bar & ~@as(u64, 0x0f);
        if (io == 0)
            continue;
        print("usbxhci: %#x %#x: port %llux size %lld irq %d\n", .{ p.vid, p.did, io, iosize, p.intl });
        const mmio = arch.vmap(io, @intCast(iosize)) orelse {
            print("usbxhci: cannot map registers\n", .{});
            continue;
        };
        const ctlr = usbxhci.xhcialloc(@ptrFromInt(mmio), io, iosize) orelse {
            print("usbxhci: no memory\n", .{});
            arch.vunmap(mmio, @intCast(iosize));
            continue;
        };
        ctlr.aux = p;
        ctlr.dmaaddr = pciwaddr;
        var i: usize = 0;
        while (i < ctlrs.len) : (i += 1) {
            if (ctlrs[i] == null) {
                ctlrs[i] = ctlr;
                break;
            }
        }
        if (i >= ctlrs.len)
            print("xhci: bug: more than %d controllers\n", .{ctlrs.len});
    }
}

fn init(hp: *Hci) Error!void {
    const ctlr: *Xhci = @ptrCast(@alignCast(hp.aux.?));
    const pcidev: *Pcidev = @ptrCast(@alignCast(ctlr.aux.?));

    if (ctlr.mmio[0] == 0xFFFFFFFF) {
        pci.pcidisable(pcidev);
        return proc.errorf("controller vanished", .{});
    }
    pci.pcisetbme(pcidev);
    try usbxhci.xhciinit(hp);
}

fn shutdown(hp: *Hci) void {
    const ctlr: *Xhci = @ptrCast(@alignCast(hp.aux.?));
    const pcidev: *Pcidev = @ptrCast(@alignCast(ctlr.aux.?));

    usbxhci.xhcishutdown(hp);
    pci.pcidisable(pcidev);
}

fn reset(hp: *Hci) i32 {
    if (arch.getconf("*nousbxhci") != null)
        return -1;

    scanpci();

    // Any adapter matches if no hp->port is supplied,
    // otherwise the ports must match.
    for (ctlrs) |c| {
        const ctlr = c orelse break;
        if (ctlr.active == null) {
            if (hp.isa.port == 0 or hp.isa.port == ctlr.base) {
                // Found:
                const pcidev: *Pcidev = @ptrCast(@alignCast(ctlr.aux.?));
                pci.pcienable(pcidev);
                usbxhci.xhcihandoff(ctlr);
                hp.isa.irq = pcidev.intl;
                hp.tbdf = pcidev.tbdf;
                usbxhci.xhcilinkage(hp, ctlr);
                hp.init = init;
                hp.shutdown = shutdown;

                return 0;
            }
        }
    }
    return -1;
}

pub fn usbxhcipcilink() void {
    devusb.addhcitype("xhci", reset);
}
