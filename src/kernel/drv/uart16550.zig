//! 16550 UART, polled output only for now.
//! from 9/pc/uarti8250.c (i8250console and the polled putc path)
//!
//! DIFF: register access goes through `Io` so the same driver serves
//! port I/O (PC) and memory-mapped (riscv64, some aarch64) UARTs.
//! `Io` must provide `read(self, reg: u3) u8` and `write(self, reg: u3, v: u8) void`.

// Register offsets.
const Rbr = 0; // Receive Buffer (RO)
const Thr = 0; // Transmit Holding (WO)
const Ier = 1; // Interrupt Enable
const Fcr = 2; // FIFO Control (WO)
const Lcr = 3; // Line Control
const Mcr = 4; // Modem Control
const Lsr = 5; // Line Status
const Dll = 0; // Divisor Latch LSB, when Lcr.Dlab
const Dlm = 1; // Divisor Latch MSB, when Lcr.Dlab

const WLS8 = 0x03; // Lcr: 8 data bits
const Dlab = 0x80; // Lcr: divisor latch access
const FIFOena = 0x01; // Fcr: enable FIFOs
const FIFOrclr = 0x02; // Fcr: clear receive FIFO
const FIFOtclr = 0x04; // Fcr: clear transmit FIFO
const Dtr = 0x01; // Mcr: data terminal ready
const Rts = 0x02; // Mcr: ready to send
const Thre = 0x20; // Lsr: transmit holding register empty

const Freq = 1843200; // UART clock on a PC

pub fn Uart16550(comptime Io: type) type {
    return struct {
        io: Io,

        const Self = @This();

        pub fn init(self: Self, baud: u32) void {
            const div: u16 = @intCast(Freq / 16 / baud);
            self.io.write(Ier, 0);
            self.io.write(Lcr, Dlab | WLS8);
            self.io.write(Dll, @truncate(div));
            self.io.write(Dlm, @truncate(div >> 8));
            self.io.write(Lcr, WLS8);
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
