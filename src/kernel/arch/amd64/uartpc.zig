//! The PC's serial ports: COM1 and COM2 on the ISA I/O ports, driven by
//! drv/uart16550.zig, and the choice of console UART.
//! from 9/pc/uarti8250.c (the port and IRQ numbers, i8250ctlr,
//! i8250uart, i8250pnp, i8250console, and the intrenable call of
//! i8250enable) and 9/pc/uartisa.c
//!
//! DIFF:
//!   - This is the part of uarti8250.c that knows about a PC; the
//!     driver proper is generic over its register access and has no
//!     port I/O.  `PortIo` is the accessor, `Drv` the driver for it.
//!   - The driver asks for its interrupt through Ctlr.intrenable
//!     (i8250intrenable here), which installs i8250interrupt, a handler
//!     of this architecture's type that calls the driver's.  There is
//!     no Ctlr.intrdisable because irq.zig has no intrdisable yet: once
//!     a port has been opened its handler stays installed, and a closed
//!     port is quiet because the driver clears its interrupt enables.
//!   - uartinit is new: it stands for the physuart[] table mkdevc
//!     writes and for main's call of i8250console.  It must run after
//!     the interrupt controllers are up and before chandevreset.
//!   - i8250console: without console= in plan9.ini, COM1 at 115200 baud
//!     is the console ("0 b115200"), because main.zig prints there from
//!     the first instruction; the C has no serial console then.  With
//!     console= the C's rules hold, 9600 baud unless it says otherwise.
//!     The settings string is copied (at most 64 bytes) before uartctl
//!     tokenizes it; the C edits plan9.ini's copy in place.
//!   - i8250console only records which UART is the console and sets
//!     its line parameters.  Kernel print stays on main.zig's polled
//!     console; nothing is rerouted through consuart.
//!   - i8250pnp and i8250console leave out a port that has no UART
//!     behind it.
//!   - uartisa.c's uartisapnp (uart2 to uart5 from plan9.ini's
//!     uartN=type=isa lines) is not ported: there is no isaconfig.
//!     i8250alloc, which it would use, is in the driver.

const dat = @import("dat.zig");
const l = @import("l.zig");
const irq = @import("irq.zig");
const bootargs = @import("bootargs.zig");
const devuart = @import("../../port/devuart.zig");
const Uart16550 = @import("../../drv/uart16550.zig").Uart16550;

const Ureg = dat.Ureg;
const Uart = devuart.Uart;
const PhysUart = devuart.PhysUart;
const uartctl = devuart.uartctl;
const uartctls = devuart.uartctls;
const getconf = bootargs.getconf;

const Uart0 = 0x3F8; // COM1
const Uart0IRQ = 4;
const Uart1 = 0x2F8; // COM2
const Uart1IRQ = 3;

const UartFREQ = 1843200;

/// Register access for a UART on the ISA I/O ports.
pub const PortIo = struct {
    base: u16,

    pub fn read(self: PortIo, reg: u3) u8 {
        return l.inb(self.base + reg);
    }

    pub fn write(self: PortIo, reg: u3, v: u8) void {
        l.outb(self.base + reg, v);
    }
};

const Drv = Uart16550(PortIo);
const Ctlr = Drv.Ctlr;

var i8250ctlr: [2]Ctlr = .{
    .{
        .io = .{ .base = Uart0 },
        .irq = Uart0IRQ,
        .tbdf = dat.BUSUNKNOWN,
        .intrenable = i8250intrenable,
    },
    .{
        .io = .{ .base = Uart1 },
        .irq = Uart1IRQ,
        .tbdf = dat.BUSUNKNOWN,
        .intrenable = i8250intrenable,
    },
};

var i8250uart: [2]Uart = .{
    .{
        .regs = &i8250ctlr[0],
        .name = "COM1",
        .freq = UartFREQ,
        .phys = &i8250physuart,
        .special = false,
        .next = &i8250uart[1],
    },
    .{
        .regs = &i8250ctlr[1],
        .name = "COM2",
        .freq = UartFREQ,
        .phys = &i8250physuart,
        .special = false,
        .next = null,
    },
};

fn i8250interrupt(_: *Ureg, arg: ?*anyopaque) void {
    Drv.i8250interrupt(@ptrCast(@alignCast(arg.?)));
}

/// The intrenable call of the C's i8250enable.
fn i8250intrenable(uart: *Uart) void {
    const ctlr: *Ctlr = @ptrCast(@alignCast(uart.regs.?));
    irq.intrenable(ctlr.irq, i8250interrupt, uart, ctlr.tbdf, uart.name);
}

/// DIFF: only the ports that have a UART behind them; the C lists
/// both always.  A machine with no serial port at all gets no eia
/// files, and nothing waits on registers that are not there.
fn i8250pnp() ?*Uart {
    var head: ?*Uart = null;
    var i = i8250uart.len;
    while (i > 0) {
        i -= 1;
        const probe: Drv = .{ .io = i8250ctlr[i].io };
        if (!probe.probe())
            continue;
        i8250uart[i].next = head;
        head = &i8250uart[i];
    }
    return head;
}

fn present(uart: *const Uart) bool {
    const ctlr: *const Ctlr = @ptrCast(@alignCast(uart.regs.?));
    const probe: Drv = .{ .io = ctlr.io };
    return probe.probe();
}

pub const i8250physuart: PhysUart = blk: {
    var phys = Drv.physuart;
    phys.pnp = i8250pnp;
    break :blk phys;
};

pub fn i8250console() void {
    // DIFF: the default; see the header.
    const p = getconf("console") orelse "0 b115200";
    const r = devuart.strtol(p, 0);
    if (r.end == 0 or r.n < 0 or r.n >= i8250uart.len)
        return;
    const uart = &i8250uart[@intCast(r.n)];
    if (!present(uart)) // DIFF: see i8250pnp
        return;

    uart.phys.enable(uart, false);
    uartctls(uart, "b9600 l8 pn s1");
    if (r.end < p.len) {
        var buf: [64]u8 = undefined;
        const cmd = p[r.end..];
        const n = @min(cmd.len, buf.len);
        @memcpy(buf[0..n], cmd[0..n]);
        uartctl(uart, buf[0..n]) catch {};
    }

    devuart.consuart = uart;
    uart.console = true;
}

const physuart = [_]*const PhysUart{
    &i8250physuart,
};

/// Tell devuart about this machine's UARTs and pick the console (see
/// DIFF).
pub fn uartinit() void {
    devuart.physuart = &physuart;
    i8250console();
}
