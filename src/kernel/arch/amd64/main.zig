//! from 9/pc64/main.c

const bootinfo = @import("bootinfo");
const mem = @import("mem.zig");
const l = @import("l.zig");
const print = @import("../../port/print.zig");
const Uart16550 = @import("../../drv/uart16550.zig").Uart16550;

const BootInfo = bootinfo.BootInfo;

/// Register access for a UART on the ISA I/O ports.
const PortIo = struct {
    base: u16,

    pub fn read(self: PortIo, reg: u3) u8 {
        return l.inb(self.base + reg);
    }

    pub fn write(self: PortIo, reg: u3, v: u8) void {
        l.outb(self.base + reg, v);
    }
};

const uart0: Uart16550(PortIo) = .{ .io = .{ .base = 0x3f8 } };

fn uartputs(s: []const u8) void {
    uart0.puts(s);
}

/// Kernel address of physical address `pa`, through the direct map.
fn kaddr(comptime T: type, pa: u64) T {
    return @ptrFromInt(mem.DMAP + pa);
}

pub fn main(bipa: u64) callconv(.c) noreturn {
    uart0.init(115200);
    print.consputs = uartputs;
    print.puts("\nPlan 9\n");

    const bi = kaddr(*const BootInfo, bipa);
    if (bi.magic != bootinfo.magic or bi.version != bootinfo.version)
        print.panic("bad boot info");
    bootsummary(bi);

    l.idle();
}

fn bootsummary(bi: *const BootInfo) void {
    const regions = kaddr([*]const bootinfo.MemRegion, bi.memmap)[0..bi.memmap_len];
    var usable: u64 = 0;
    for (regions) |r| {
        if (r.kind == .usable) usable += r.pages;
    }

    print.puts("kernel ");
    print.hex(bi.kernel_virt);
    print.puts(" at pa ");
    print.hex(bi.kernel_phys);
    print.puts(" size ");
    print.dec(bi.kernel_size / mem.KiB);
    print.puts("K\n");

    print.puts("memory ");
    print.dec(usable * mem.BY2PG / mem.MiB);
    print.puts("M usable in ");
    print.dec(regions.len);
    print.puts(" regions\n");

    print.puts("acpi rsdp ");
    print.hex(bi.acpi_rsdp);
    print.puts("\n");

    const fb = bi.framebuffer;
    if (fb.format != .none) {
        print.puts("framebuffer ");
        print.dec(fb.width);
        print.puts("x");
        print.dec(fb.height);
        print.puts(" at pa ");
        print.hex(fb.base);
        print.puts("\n");
    }
}
