//! 8250 UART and compatibles (16450, 16550): the PhysUart driver behind
//! devuart, and a polled output path for the kernel's early console.
//! from 9/pc/uarti8250.c
//!
//! DIFF:
//!   - Register access goes through `Io`, so the same driver serves port
//!     I/O (PC) and memory-mapped (riscv64, some aarch64) UARTs.  `Io`
//!     must provide `read(self, reg: u3) u8` and
//!     `write(self, reg: u3, v: u8) void`; it takes the place of the
//!     C's Ctlr.io port number.  The driver is the type
//!     `Uart16550(Io)`; each instantiation has its own Ctlr, functions
//!     and PhysUart table (`physuart`).
//!   - The driver does not call intrenable or intrdisable: what an
//!     interrupt is and how it is routed belongs to the platform.  The
//!     platform puts two functions in the Ctlr.  i8250enable calls
//!     `intrenable(uart)` where the C calls intrenable; the platform's
//!     function installs a handler that calls `i8250interrupt(uart)`.
//!     i8250disable calls `intrdisable(uart)`; if there is none the
//!     handler stays installed (iena stays set) and only the UART's own
//!     interrupt enables are cleared.  A callback was chosen over having
//!     the platform enable the interrupt itself because it keeps
//!     i8250enable's order (handler first, then Ier, then the call that
//!     clears a pending interrupt) and its "ie" argument as in the C.
//!   - i8250interrupt takes the Uart, not (Ureg*, void*): the handler
//!     type is the platform's.
//!   - The table of UARTs (i8250ctlr, i8250uart), i8250pnp and
//!     i8250console are the platform's: see arch/amd64/uartpc.zig.
//!     `physuart.pnp` is null here; the platform copies the table and
//!     fills it in.
//!   - i8250break returns an error if its sleep is interrupted, and
//!     takes the break condition off first; the C leaves it on.
//!   - `Mmio` and `mmiophysuart` are not in the C: register access for
//!     a memory-mapped UART, and the driver instantiated for it.  No
//!     platform uses them yet; they are here so that `zig build
//!     check-ports` compiles the whole driver for the other
//!     architectures, which a generic function alone does not do.
//!   - `probe`, `init`, `putc` and `puts` at the end are not in the C.  They are
//!     the polled console the kernel uses from its first instructions,
//!     before there is a Uart, a clock or an allocator.

const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const taslock = @import("../port/taslock.zig");
const alloc = @import("../port/alloc.zig");
const proc = @import("../port/proc.zig");
const devuart = @import("../port/devuart.zig");
const p9 = @import("../port/print.zig");

const print = p9.print;
const iprint = p9.iprint;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const Lock = portdat.Lock;
const Uart = devuart.Uart;
const PhysUart = devuart.PhysUart;
const uartkick = devuart.uartkick;
const uartrecv = devuart.uartrecv;
const uartstageoutput = devuart.uartstageoutput;

const Freq = 1843200; // UART clock on a PC

// I/O ports
const Rbr = 0; // Receiver Buffer (RO)
const Thr = 0; // Transmitter Holding (WO)
const Ier = 1; // Interrupt Enable
const Iir = 2; // Interrupt Identification (RO)
const Fcr = 2; // FIFO Control (WO)
const Lcr = 3; // Line Control
const Mcr = 4; // Modem Control
const Lsr = 5; // Line Status
const Msr = 6; // Modem Status
const Scr = 7; // Scratch Pad
const Dll = 0; // Divisor Latch LSB
const Dlm = 1; // Divisor Latch MSB

// Ier
const Erda = 0x01; // Enable Received Data Available
const Ethre = 0x02; // Enable Thr Empty
const Erls = 0x04; // Enable Receiver Line Status
const Ems = 0x08; // Enable Modem Status

// Iir
const Ims = 0x00; // Ms interrupt
const Ip = 0x01; // Interrupt Pending (not)
const Ithre = 0x02; // Thr Empty
const Irda = 0x04; // Received Data Available
const Irls = 0x06; // Receiver Line Status
const Ictoi = 0x0C; // Character Time-out Indication
const IirMASK = 0x3F;
const Ifena = 0xC0; // FIFOs enabled

// Fcr
const FIFOena = 0x01; // FIFO enable
const FIFOrclr = 0x02; // clear Rx FIFO
const FIFOtclr = 0x04; // clear Tx FIFO
const FIFO1 = 0x00; // Rx FIFO trigger level 1 byte
const FIFO4 = 0x40; //  4 bytes
const FIFO8 = 0x80; //  8 bytes
const FIFO14 = 0xC0; //  14 bytes

// Lcr
const Wls5 = 0x00; // Word Length Select 5 bits/byte
const Wls6 = 0x01; //  6 bits/byte
const Wls7 = 0x02; //  7 bits/byte
const Wls8 = 0x03; //  8 bits/byte
const WlsMASK = 0x03;
const Stb = 0x04; // 2 stop bits
const Pen = 0x08; // Parity Enable
const Eps = 0x10; // Even Parity Select
const Stp = 0x20; // Stick Parity
const Brk = 0x40; // Break
const Dlab = 0x80; // Divisor Latch Access Bit

// Mcr
const Dtr = 0x01; // Data Terminal Ready
const Rts = 0x02; // Ready To Send
const Out1 = 0x04; // no longer in use
const Ie = 0x08; // IRQ Enable
const Dm = 0x10; // Diagnostic Mode loopback

// Lsr
const Dr = 0x01; // Data Ready
const Oe = 0x02; // Overrun Error
const Pe = 0x04; // Parity Error
const Fe = 0x08; // Framing Error
const Bi = 0x10; // Break Interrupt
const Thre = 0x20; // Thr Empty
const Temt = 0x40; // Tramsmitter Empty
const FIFOerr = 0x80; // error in receiver FIFO

// Msr
const Dcts = 0x01; // Delta Cts
const Ddsr = 0x02; // Delta Dsr
const Teri = 0x04; // Trailing Edge of Ri
const Ddcd = 0x08; // Delta Dcd
const Cts = 0x10; // Clear To Send
const Dsr = 0x20; // Data Set Ready
const Ri = 0x40; // Ring Indicator
const Dcd = 0x80; // Data Set Ready

pub fn Uart16550(comptime Io: type) type {
    return struct {
        io: Io,

        const Self = @This();

        pub const Ctlr = struct {
            io: Io,
            irq: i32 = -1,
            tbdf: i32 = -1,
            iena: bool = false,

            sticky: [8]u8 = @splat(0),

            lock: Lock = .{},
            hasfifo: bool = false,
            checkfifo: bool = false,
            fena: i32 = 0,

            /// Arrange for i8250interrupt(uart) to be called on the
            /// UART's interrupt, and stop that (see DIFF).
            intrenable: ?*const fn (uart: *Uart) void = null,
            intrdisable: ?*const fn (uart: *Uart) void = null,
        };

        fn regs(uart: *Uart) *Ctlr {
            return @ptrCast(@alignCast(uart.regs.?));
        }

        fn csr8r(c: *Ctlr, r: u3) u8 {
            return c.io.read(r);
        }

        fn csr8w(c: *Ctlr, r: u3, v: u8) void {
            c.io.write(r, c.sticky[r] | v);
        }

        fn i8250status(uart: *Uart, buf: []u8) []u8 {
            const ctlr = regs(uart);
            const mcr = ctlr.sticky[Mcr];
            const msr = csr8r(ctlr, Msr);
            const ier = ctlr.sticky[Ier];
            const lcr = ctlr.sticky[Lcr];
            return fmt.snprint(buf, "b%d c%d d%d e%d l%d m%d p%c r%d s%d i%d\n" ++
                "dev(%d) type(%d) framing(%d) overruns(%d) " ++
                "berr(%d) serr(%d)%s%s%s%s\n", .{
                uart.baud,
                uart.hup_dcd,
                @intFromBool(msr & Dsr != 0),
                uart.hup_dsr,
                @as(u32, lcr & WlsMASK) + 5,
                @intFromBool(ier & Ems != 0),
                @as(u8, if (lcr & Pen != 0) (if (lcr & Eps != 0) 'e' else 'o') else 'n'),
                @intFromBool(mcr & Rts != 0),
                @as(u32, if (lcr & Stb != 0) 2 else 1),
                ctlr.fena,

                uart.dev,
                uart.type,
                uart.ferr,
                uart.oerr,
                uart.berr,
                uart.serr,
                if (msr & Cts != 0) " cts" else "",
                if (msr & Dsr != 0) " dsr" else "",
                if (msr & Dcd != 0) " dcd" else "",
                if (msr & Ri != 0) " ring" else "",
            });
        }

        fn i8250fifo(uart: *Uart, level_: i32) void {
            const ctlr = regs(uart);
            if (!ctlr.hasfifo)
                return;

            // Changing the FIFOena bit in Fcr flushes data
            // from both receive and transmit FIFOs; there's
            // no easy way to guarantee not losing data on
            // the receive side, but it's possible to wait until
            // the transmitter is really empty.
            ilock(&ctlr.lock);
            while (csr8r(ctlr, Lsr) & Temt == 0) {}

            // Set the trigger level, default is the max.
            // value.
            // Some UARTs require FIFOena to be set before
            // other bits can take effect, so set it twice.
            ctlr.fena = level_;
            const level: u8 = switch (level_) {
                0 => 0,
                1 => FIFO1 | FIFOena,
                4 => FIFO4 | FIFOena,
                8 => FIFO8 | FIFOena,
                else => FIFO14 | FIFOena,
            };
            csr8w(ctlr, Fcr, level);
            csr8w(ctlr, Fcr, level);
            iunlock(&ctlr.lock);
        }

        fn i8250dtr(uart: *Uart, on: i32) void {
            // Toggle DTR.
            const ctlr = regs(uart);
            if (on != 0)
                ctlr.sticky[Mcr] |= Dtr
            else
                ctlr.sticky[Mcr] &= ~@as(u8, Dtr);
            csr8w(ctlr, Mcr, 0);
        }

        fn i8250rts(uart: *Uart, on: i32) void {
            // Toggle RTS.
            const ctlr = regs(uart);
            if (on != 0)
                ctlr.sticky[Mcr] |= Rts
            else
                ctlr.sticky[Mcr] &= ~@as(u8, Rts);
            csr8w(ctlr, Mcr, 0);
        }

        fn i8250modemctl(uart: *Uart, on: i32) void {
            const ctlr = regs(uart);
            ilock(&uart.tlock);
            if (on != 0) {
                ctlr.sticky[Ier] |= Ems;
                csr8w(ctlr, Ier, ctlr.sticky[Ier]);
                uart.modem = true;
                uart.cts = csr8r(ctlr, Msr) & Cts != 0;
            } else {
                ctlr.sticky[Ier] &= ~@as(u8, Ems);
                csr8w(ctlr, Ier, ctlr.sticky[Ier]);
                uart.modem = false;
                uart.cts = true;
            }
            iunlock(&uart.tlock);

            // modem needs fifo
            uart.phys.fifo(uart, on);
        }

        fn i8250parity(uart: *Uart, parity: i32) i32 {
            const ctlr = regs(uart);
            var lcr: u8 = ctlr.sticky[Lcr] & ~@as(u8, Eps | Pen);

            switch (parity) {
                'e' => lcr |= Eps | Pen,
                'o' => lcr |= Pen,
                'n' => {},
                else => return -1,
            }
            ctlr.sticky[Lcr] = lcr;
            csr8w(ctlr, Lcr, 0);

            uart.parity = parity;

            return 0;
        }

        fn i8250stop(uart: *Uart, stop: i32) i32 {
            const ctlr = regs(uart);
            var lcr: u8 = ctlr.sticky[Lcr] & ~@as(u8, Stb);

            switch (stop) {
                1 => {},
                2 => lcr |= Stb,
                else => return -1,
            }
            ctlr.sticky[Lcr] = lcr;
            csr8w(ctlr, Lcr, 0);

            uart.stop = stop;

            return 0;
        }

        fn i8250bits(uart: *Uart, bits: i32) i32 {
            const ctlr = regs(uart);
            var lcr: u8 = ctlr.sticky[Lcr] & ~@as(u8, WlsMASK);

            switch (bits) {
                5 => lcr |= Wls5,
                6 => lcr |= Wls6,
                7 => lcr |= Wls7,
                8 => lcr |= Wls8,
                else => return -1,
            }
            ctlr.sticky[Lcr] = lcr;
            csr8w(ctlr, Lcr, 0);

            uart.bits = bits;

            return 0;
        }

        fn i8250baud(uart: *Uart, baud: i32) i32 {
            // Set the Baud rate by calculating and setting the Baud rate
            // Generator Constant. This will work with fairly non-standard
            // Baud rates.
            if (uart.freq == 0 or baud <= 0)
                return -1;
            const b: u32 = @intCast(baud);
            const bgc: u32 = (uart.freq +% 8 *% b -% 1) / (16 *% b);

            const ctlr = regs(uart);
            csr8w(ctlr, Lcr, Dlab);
            ctlr.io.write(Dlm, @truncate(bgc >> 8));
            ctlr.io.write(Dll, @truncate(bgc));
            csr8w(ctlr, Lcr, 0);

            uart.baud = baud;

            return 0;
        }

        fn i8250break(uart: *Uart, ms_: i32) proc.Error!void {
            // Send a break.
            const ms: u32 = if (ms_ <= 0) 200 else @intCast(ms_);

            const ctlr = regs(uart);
            csr8w(ctlr, Lcr, Brk);
            defer csr8w(ctlr, Lcr, 0);
            try proc.tsleep(&arch.up().?.sleep, proc.return0, null, ms);
        }

        fn i8250kick(uart: *Uart) void {
            if (!uart.cts)
                return;

            // 128 here is an arbitrary limit to make sure
            // we don't stay in this loop too long.  If the
            // chip's output queue is longer than 128, too
            // bad -- presotto
            const ctlr = regs(uart);
            for (0..128) |_| {
                if (csr8r(ctlr, Lsr) & Thre == 0)
                    break;
                if (uart.op >= uart.oe and uartstageoutput(uart) == 0)
                    break;
                ctlr.io.write(Thr, uart.ostage[uart.op]);
                uart.op += 1;
            }
        }

        /// The interrupt handler; the platform's handler calls it with
        /// the Uart it was given by Ctlr.intrenable.
        pub fn i8250interrupt(uart: *Uart) void {
            const ctlr = regs(uart);
            var iir = csr8r(ctlr, Iir);
            while (iir & Ip == 0) : (iir = csr8r(ctlr, Iir)) {
                switch (iir & IirMASK) {
                    Ims => { // Ms interrupt
                        const r = csr8r(ctlr, Msr);
                        if (r & Dcts != 0) {
                            ilock(&uart.tlock);
                            const old = uart.cts;
                            uart.cts = r & Cts != 0;
                            if (!old and uart.cts)
                                uart.ctsbackoff = 2;
                            iunlock(&uart.tlock);
                        }
                        if (r & Ddsr != 0) {
                            const old = r & Dsr != 0;
                            if (uart.hup_dsr != 0 and uart.dsr and !old)
                                uart.dohup = true;
                            uart.dsr = old;
                        }
                        if (r & Ddcd != 0) {
                            const old = r & Dcd != 0;
                            if (uart.hup_dcd != 0 and uart.dcd and !old)
                                uart.dohup = true;
                            uart.dcd = old;
                        }
                    },
                    Ithre => uartkick(uart), // Thr Empty
                    Irda, // Received Data Available
                    Irls, // Receiver Line Status
                    Ictoi, // Character Time-out Indication
                    => {
                        // Consume any received data.
                        // If the received byte came in with a break,
                        // parity or framing error, throw it away;
                        // overrun is an indication that something has
                        // already been tossed.
                        while (true) {
                            const lsr = csr8r(ctlr, Lsr);
                            if (lsr & Dr == 0)
                                break;
                            if (lsr & (FIFOerr | Oe) != 0)
                                uart.oerr +%= 1;
                            if (lsr & Pe != 0)
                                uart.perr +%= 1;
                            if (lsr & Fe != 0)
                                uart.ferr +%= 1;
                            const r = csr8r(ctlr, Rbr);
                            if (lsr & (Bi | Fe | Pe) == 0)
                                uartrecv(uart, r);
                        }
                    },
                    else => iprint("weird uart interrupt 0x%2.2uX\n", .{iir}),
                }
            }
        }

        fn i8250disable(uart: *Uart) void {
            // Turn off DTR and RTS, disable interrupts and fifos.
            uart.phys.dtr(uart, 0);
            uart.phys.rts(uart, 0);
            uart.phys.fifo(uart, 0);

            const ctlr = regs(uart);
            ctlr.sticky[Ier] = 0;
            csr8w(ctlr, Ier, ctlr.sticky[Ier]);

            if (ctlr.iena) {
                // DIFF: see the header.
                if (ctlr.intrdisable) |intrdisable| {
                    ctlr.iena = false;
                    intrdisable(uart);
                }
            }
        }

        fn i8250enable(uart: *Uart, ie: bool) void {
            const ctlr = regs(uart);

            // Check if there is a FIFO.
            // Changing the FIFOena bit in Fcr flushes data
            // from both receive and transmit FIFOs; there's
            // no easy way to guarantee not losing data on
            // the receive side, but it's possible to wait until
            // the transmitter is really empty.
            // Also, reading the Iir outwith i8250interrupt()
            // can be dangerous, but this should only happen
            // once before interrupts are enabled.
            ilock(&ctlr.lock);
            if (!ctlr.checkfifo) {
                // Wait until the transmitter is really empty.
                while (csr8r(ctlr, Lsr) & Temt == 0) {}
                csr8w(ctlr, Fcr, FIFOena);
                if (csr8r(ctlr, Iir) & Ifena != 0)
                    ctlr.hasfifo = true;
                csr8w(ctlr, Fcr, 0);
                ctlr.checkfifo = true;
            }
            iunlock(&ctlr.lock);

            // Enable interrupts and turn on DTR and RTS.
            // Be careful if this is called to set up a polled serial line
            // early on not to try to enable interrupts as interrupt-
            // -enabling mechanisms might not be set up yet.
            if (ie) {
                if (!ctlr.iena) {
                    // DIFF: see the header.
                    if (ctlr.intrenable) |intrenable|
                        intrenable(uart);
                    ctlr.iena = true;
                }
                ctlr.sticky[Ier] = Ethre | Erda;
                ctlr.sticky[Mcr] |= Ie;
            } else {
                ctlr.sticky[Ier] = 0;
                ctlr.sticky[Mcr] = 0;
            }
            csr8w(ctlr, Ier, ctlr.sticky[Ier]);
            csr8w(ctlr, Mcr, ctlr.sticky[Mcr]);

            uart.phys.dtr(uart, 1);
            uart.phys.rts(uart, 1);

            // During startup, the i8259 interrupt controller is reset.
            // This may result in a lost interrupt from the i8250 uart.
            // The i8250 thinks the interrupt is still outstanding and does not
            // generate any further interrupts. The workaround is to call the
            // interrupt handler to clear any pending interrupt events.
            // Note: this must be done after setting Ier.
            if (ie)
                i8250interrupt(uart);
        }

        pub fn i8250alloc(io: Io, irq: i32, tbdf: i32) ?*Ctlr {
            const ctlr = alloc.new(Ctlr) orelse {
                print("i8250alloc: no memory for Ctlr\n", .{});
                return null;
            };
            ctlr.* = .{ .io = io, .irq = irq, .tbdf = tbdf };
            return ctlr;
        }

        fn i8250getc(uart: *Uart) i32 {
            const ctlr = regs(uart);
            while (csr8r(ctlr, Lsr) & Dr == 0)
                arch.delay(1);
            return csr8r(ctlr, Rbr);
        }

        fn i8250putc(uart: *Uart, c: i32) void {
            const ctlr = regs(uart);
            var i: u32 = 0;
            while (csr8r(ctlr, Lsr) & Thre == 0 and i < 128) : (i += 1)
                arch.delay(1);
            ctlr.io.write(Thr, @truncate(@as(u32, @bitCast(c))));
            i = 0;
            while (csr8r(ctlr, Lsr) & Thre == 0 and i < 128) : (i += 1)
                arch.delay(1);
        }

        /// DIFF: without pnp; see the header.
        pub const physuart: PhysUart = .{
            .name = "i8250",
            .enable = i8250enable,
            .disable = i8250disable,
            .kick = i8250kick,
            .dobreak = i8250break,
            .baud = i8250baud,
            .bits = i8250bits,
            .stop = i8250stop,
            .parity = i8250parity,
            .modemctl = i8250modemctl,
            .rts = i8250rts,
            .dtr = i8250dtr,
            .status = i8250status,
            .fifo = i8250fifo,
            .getc = i8250getc,
            .putc = i8250putc,
        };

        // The polled early console (see DIFF): no Uart, no Ctlr, no
        // locks, no clock.

        /// Is there a UART behind `io`?  Where nothing decodes the
        /// address every register reads the same (all ones on a PC),
        /// and then i8250enable's wait for the transmitter could last
        /// for ever and every polled character would cost a timeout.
        /// The scratch register of a 16450 or later keeps what was
        /// written to it.
        pub fn probe(self: Self) bool {
            if (self.io.read(Lsr) == 0xFF)
                return false;
            const old = self.io.read(Scr);
            defer self.io.write(Scr, old);
            for ([_]u8{ 0x5A, 0xA5 }) |v| {
                self.io.write(Scr, v);
                if (self.io.read(Scr) != v)
                    return false;
            }
            return true;
        }

        pub fn init(self: Self, baud: u32) void {
            const div: u16 = @intCast(Freq / 16 / baud);
            self.io.write(Ier, 0);
            self.io.write(Lcr, Dlab | Wls8);
            self.io.write(Dll, @truncate(div));
            self.io.write(Dlm, @truncate(div >> 8));
            self.io.write(Lcr, Wls8);
            self.io.write(Fcr, FIFOena | FIFOrclr | FIFOtclr);
            self.io.write(Mcr, Dtr | Rts);
        }

        pub fn putc(self: Self, c: u8) void {
            // Bounded wait, so a missing UART cannot hang the kernel.
            var i: u32 = 0;
            while (self.io.read(Lsr) & Thre == 0 and i < 100000) : (i += 1) {}
            self.io.write(Thr, c);
        }

        pub fn puts(self: Self, s: []const u8) void {
            for (s) |c| {
                if (c == '\n') self.putc('\r');
                self.putc(c);
            }
        }
    };
}

/// Register access for a memory-mapped UART: byte-wide registers
/// `1 << regshift` bytes apart (see DIFF).
pub const Mmio = struct {
    base: [*]volatile u8,
    regshift: u3 = 0,

    pub fn read(self: Mmio, reg: u3) u8 {
        return self.base[@as(usize, reg) << self.regshift];
    }

    pub fn write(self: Mmio, reg: u3, v: u8) void {
        self.base[@as(usize, reg) << self.regshift] = v;
    }
};

pub const mmiophysuart: *const PhysUart = &Uart16550(Mmio).physuart;
