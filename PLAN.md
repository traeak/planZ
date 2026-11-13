# planZ — a lean 9front kernel in Zig

Source of truth: `~/master/9front` (commit `aea3a900e`). Zig 0.17.0. Test machine: QEMU.

## Decisions

| Question | Decision |
|---|---|
| Where to start | Kernel first; userland later |
| First architecture | amd64. aarch64 and riscv64 must stay possible (see "Portability rules") |
| Hardware baseline | 2011 and later (Intel Sandy Bridge, AMD Bulldozer) and QEMU: 64-bit, UEFI, ACPI, APIC, PCIe, MSI. See "CPU baseline" |
| Style | **Faithful interfaces, lean internals.** What programs observe is ported exactly; the platform layer is written fresh; optional subsystems are left out |
| ABI | Plan 9 amd64 syscall ABI and a.out loader are kept, so stock 9front binaries run |

## CPU baseline

**Required** (the kernel panics at boot without them): XSAVE, invariant TSC, NX, SYSCALL/SYSRET, local APIC.

**Used when CPUID reports them, never required:** x2APIC, TSC-deadline timer, RDRAND/RDSEED, 1GiB pages, PCID, SMEP, SMAP, XSAVEOPT. Each is a feature check, not a second implementation of a subsystem. They cannot be required because AMD gained TSC-deadline and x2APIC only with Zen-era parts, years after Intel.

Consequences:

- `fpu.c` is ported with the XSAVE path only; the FXSAVE path and the `fpsave`/`fprestore` function-pointer switch are dropped (`// DIFF: xsave only`).
- The xAPIC (memory-mapped) path is the baseline; x2APIC is the optional one.
- The timer must work in LAPIC one-shot/periodic mode calibrated against HPET; TSC-deadline is the optional one.
- Stock 9front binaries need nothing beyond SSE2, so the baseline constrains only the kernel.
- Default test CPU is QEMU `SandyBridge`; `-Dcpu=Opteron_G4` is the AMD counterpart and `-Dcpu=max` the newest. A milestone is done only when `test-boot` passes on all three. (`Opteron_G4` has to be written `Opteron_G4,+xsaveopt`; see the notes from M2.)

## What is kept exactly

These define Plan 9 to user programs. Port them file-for-file from `9/port`, keeping names and function order, with a `// from 9/port/x.c` header and `// DIFF:` comments where the Zig deliberately differs.

- Namespace: `chan`, `dev`, `pgrp` (mount table, unions, `namec`, `..` handling).
- 9P client: `devmnt` including flush and interrupt handling; `convM2S`/`convS2M`/`convD2M`/`convM2D`.
- Processes: `proc`, `sysproc` (`rfork`, `exec`, notes, `await`, rendezvous, semaphores), `sysfile`.
- Memory: `segment`, `page`, `fault`, the text image cache; `segattach`/`segbrk` semantics.
- Queues: `qio`, `allocb` (trimmed API, same design).
- Locks: `Lock`, `ilock`, `QLock`, `RWLock`, `Rendez`.
- Devices and their text formats: `root`, `cons`, `env`, `pipe`, `dup`, `srv`, `proc`, `mnt`, `rtc`, `uart`, `sd`, `ether`, `ip`, `tls`, `cap`, later `draw`, `mouse`, `kbd`, `usb`, `audio`.

## What is dropped or replaced

| Area | 9front | planZ |
|---|---|---|
| Error handling | `waserror`/`poperror` (711 sites) | Zig error unions, `defer`/`errdefer` |
| Swap | `devswap.c` + pager hooks | None. `/dev/swap` stays as a read-only memory-stats file |
| Real-time scheduling | `edf.c` + hooks in `proc.c` | Left out now. **Future addition — see "Future additions"** |
| Legacy syscalls | `_read`, `_write`, `_stat`, `_mount`, `_wait`, `_errstr`, `_nsec`, … | Return an error |
| Page colouring | In every `Page` | Dropped |
| Mount cache | `cache.c` | Dropped at first; performance only |
| Allocator | `xalloc` + `pool.c` | Small Zig allocator behind `malloc`/`smalloc`/`free` |
| Formatting | libc fmt | Only the `%` verbs the kernel uses |
| Config | `pc64` file + `mkdevc` | Comptime tables in `conf/` |
| Crypto | `libsec`, `libmp` | `std.crypto` (ciphers, hashes, RNG) |
| IP | il, rudp, gre, ipmux | Not ported. Keep ipv4/v6, arp, icmp, icmp6, udp, tcp, ipifc |
| Optional devices | vmx, dtracy, aoe, bridge, shr, fs, kprof, segment | Not ported until wanted |
| Interrupt controllers | 8259 PIC, MP tables | LAPIC + IOAPIC from the ACPI MADT |
| PCI interrupts | INTx routed through ACPI AML (`libaml`) | MSI/MSI-X on PC. No AML interpreter |
| PCI config access | Ports 0xCF8/0xCFC, PCI BIOS | ECAM (memory-mapped, from ACPI MCFG) |
| Timers | 8253 PIT | HPET for calibration, LAPIC timer for ticks, invariant TSC for fast ticks |
| FPU state | FXSAVE and XSAVE paths chosen at boot | XSAVE only |
| Display | CGA text, VGA drivers, real-mode VESA | Linear framebuffer handed over by the boot loader |
| Storage / net drivers | ~60 drivers incl. IDE, ISA, PCMCIA | virtio-blk, virtio-net, NVMe, AHCI, xHCI; real NICs as needed |
| Boot | 32-bit multiboot, BIOS e820 | UEFI loader written in Zig, passes a `BootInfo` |

## Portability rules (aarch64, riscv64)

The amd64 port is the only one being written, but these are kept so the others are additive work, not a rewrite.

1. **Port/arch split.** `src/kernel/port` never names an x86 concept. Everything machine-specific sits behind one arch interface: `mmu` (putmmu, flushmmu, mmuswitch, kmap), trap and syscall entry, `setlabel`/`gotolabel`, `splhi`/`spllo`, `procsetup`/`procsave`/`procrestore`/`procfork`, `touser`, `forkret`, `execregs`, `userureg`, `fastticks`, `timerset`, `idlehands`, `m()`/`up()`.
2. **`coherence()` and atomics stay.** x86 is strongly ordered so these look like no-ops, but aarch64 and riscv64 are not. Keep every barrier from the original port code; use Zig atomics with explicit orderings instead of plain loads and stores for shared flags.
3. **Icache flushing stays.** The per-page text-flush hook (`txtflush`, `Segment.flushme`) is needed on aarch64 and riscv64. It is an arch hook that compiles to nothing on amd64. (This reverses the earlier idea of deleting it.)
4. **No port I/O outside `arch/amd64`.** Shared drivers use MMIO accessors only. This is why PCI config goes through ECAM and virtio uses the 1.0 "modern" interface.
5. **Bus-neutral drivers.** virtio has two transports (PCI now, virtio-mmio later for the QEMU `virt` boards). NVMe, AHCI and xHCI are plain PCI + MMIO and live in `port/`.
6. **Interrupts behind one interface.** `intrenable(irq, handler, arg, bus, name)` as in 9front. Behind it: LAPIC/IOAPIC on amd64, GIC on aarch64, PLIC/AIA on riscv64. MSI-only is an amd64 choice; the interface must allow a static INTx routing table, which device-tree platforms use.
7. **Hardware discovery behind one interface.** ACPI static tables on PC; device tree on most aarch64/riscv64 boards. Kernel code asks "where is the UART / interrupt controller / PCI host bridge", never parses MADT inline.
8. **One boot contract.** The kernel entry takes a `BootInfo` (memory map, framebuffer, ACPI RSDP or DTB pointer, command line, boot files). UEFI exists on all three architectures, so the same Zig loader source serves them all.
9. **Console UART behind `PhysUart`.** 16550 on PC and riscv64, PL011 on aarch64.
10. **Shared assumptions, stated once:** 64-bit, little-endian, 4K pages, 4-level radix page tables with 9 bits per level. That lets the page-table walker live in `port/` with only PTE bit encoding per arch, and lets `kmap` be a direct-map offset everywhere.
11. **Per-arch ABI files.** `Ureg`, `Tos` placement, syscall argument passing, note frames and the a.out magic differ per architecture; they live in `arch/<name>/abi.zig`, not in `sysproc`.
12. **Keep it honest.** From M2 on, `zig build check-ports` compiles `port/` for aarch64 and riscv64 against stub arch modules.

Note on riscv64: 9front has an arm64 port (`9/arm64`, `9/bcm64`, …) to follow, but no riscv64 port, compiler or userland. A riscv64 planZ would have no stock binaries to run until userland is built with Zig.

## Repository layout

```
build.zig
PLAN.md
src/
  boot/                   UEFI loader (Zig, target *-uefi), BootInfo definition
  kernel/
    port/                 portable kernel, file-for-file with 9/port where listed above
    arch/amd64/           entry, mmu, trap, fpu, apic, hpet, abi, low-level asm
    plat/                 acpi tables, (later) device tree, framebuffer console
    drv/                  pci (ECAM), virtio, nvme, ahci, xhci, uart16550
    ip/                   trimmed 9/ip
    conf/                 comptime device and driver tables per target
  lib/                    fmt, utf, fcall (9P), alloc
  user/                   initcode; later ported userland
tools/                    mkaout, bootdir embedding, qemu test runner
ref/                      (gitignored) 9front ISO contents for reference binaries
```

## Conventions

1. **Naming.** Original identifiers (`newproc`, `namec`, `Chan`, `devtab`) throughout the ported core.
2. **Errors.** One kernel error set mirroring `port/error.h` with a comptime tag→string table, plus `error.Str` meaning "the message is in `up.errstr`". Every blocking primitive returns an error union, since a note can interrupt it. Each `waserror` site is converted by reading it, not mechanically.
3. **`m()` / `up()`.** Inline arch functions (`GS:0` on amd64). `setlabel`/`gotolabel` exist only for the scheduler.
4. **Dev.** Struct of function pointers as in C, minus `power` and `config`; `bread`/`bwrite` and other defaults are filled in at comptime.
5. **Types.** `extern struct` only where layout is ABI or hardware. `uintptr`→`usize`, `ulong`→`u32`, `vlong`→`i64`.
6. **Kernel build flags.** Freestanding, code model `kernel`, no red zone, no SSE/AVX/x87 in kernel code, no PIC, frame pointers on. ReleaseSafe by default (8K kernel stacks).

## Milestones

Each ends with something visible on the QEMU serial console, checked by `zig build test-boot` (headless QEMU with UEFI firmware, expected-output match, timeout). Pure-logic modules also get host unit tests under `zig build test`.

### M0 — Boot contract
- New `build.zig`: UEFI loader, kernel ELF, FAT boot directory, `run` and `test-boot` steps.
- Loader: load kernel ELF, get memory map, GOP framebuffer, RSDP; build initial page tables (direct map + kernel at `KZERO`); exit boot services; jump with `BootInfo`.
- Kernel: 16550 polled output.
- **Done when:** `zig build run` prints `Plan 9` from the kernel's high-half address.

### M1 — Machine core
`fmt`, `print`, `panic`; physical memory from `BootInfo`; page-table walker and kernel map; allocator; GDT/IDT/TSS and fault dump; ACPI table lookup (MADT, HPET, MCFG); LAPIC + IOAPIC; HPET calibration and LAPIC timer tick; `intrenable`.
- **Done when:** memory map printed, allocator stress passes, timer ticks, a deliberate fault prints registers.

### M2 — Processes
`proc` (scheduler without EDF), `taslock`, `qlock`, `portclock`, `tod`, `alarm`, `kproc`, kernel-side FPU state. `check-ports` build step added.
- **Done when:** several kprocs sleep/wakeup under preemption for a minute. (Rendezvous needs `Rgrp` and is a system call; it is tested in M4.)

### M3 — Channels and namespace
`chan`, `dev`, `pgrp`, `qio`, `allocb`, `parse`, `fcall`; `devroot`, `devcons`, `devenv`, `devpipe`, `devdup`, `devsrv`.
- **Done when:** an in-kernel test walks `#/`, binds `#c` on `/dev`, writes `/dev/cons`, round-trips a pipe.

### M4 — User mode
`segment`, `page`, `fault`, image cache, `sysfile`, `sysproc`, syscall table, SYSCALL/SYSRET entry, `touser`, user FPU state, `tools/mkaout`, initcode.
- ABI facts: syscall number in RBP, arguments on the user stack, entry at `UTZERO+0x28`, `Tos` at the top of the stack.
- Needs the 9front amd64 ISO in `ref/` (ask the user before downloading).
- **Done when:** an unmodified 9front `/amd64/bin/echo` served from `#/boot` prints to the console.

### M5 — Boot to `rc`
`devmnt`, `devproc`, `devrtc`, `devuart` with interrupts, `random`, stats-only `/dev/swap`, boot files (`boot`, `paqfs`, `factotum`, `bootfs.paq`) loaded by the UEFI loader and exposed in `#/boot`.
- **Done when:** stock `boot` → `paqfs` → `bootrc` reaches an interactive `rc` on serial; `ls /dev`, `cat /dev/time`, `ps` work.

### M6 — SMP
AP startup, per-CPU state, TLB shootdown, `-smp 4`.
- **Done when:** all CPUs schedule and a parallel workload survives an hour.

### M7 — Storage and network
PCI over ECAM with MSI/MSI-X; `devsd` + virtio-blk, NVMe, AHCI; trimmed `9/ip`; `devether` + virtio-net; `devtls` on `std.crypto`; `devcap`, `auth`.
- **Done when:** boots a real 9front disk image (stock gefs, cwfs or hjfs), gets a DHCP lease, `hget` over TLS works.

### M8 — Graphics and input
Framebuffer `screen`, `libmemdraw`, `libmemlayer`, `devdraw`, `devmouse`, `devkbd`, xHCI + USB HID.
- **Done when:** stock `rio` runs.

### M9 — Real hardware
Boot on one physical 2011-or-later machine; add the NIC and quirks it needs; audio (HDA) if wanted.

The user's test machine: AMD Ryzen 5 3600 (Zen 2) on a Jingyue B550i mini-ITX board, 32GB RAM, Radeon RX 6500 XT. It has no integrated graphics, so the display is the card's UEFI framebuffer. Assume no serial console. The development machine has the same board (DMI: JGINYUE B550i-GAMING), so its hardware can be read from Linux there: Ethernet is a Realtek RTL8125B (`10ec:8125` rev 05), for which 9front has no driver at this commit; two xHCI controllers (AMD 500-series chipset `1022:43ee`, Matisse `1022:149c`); AMD AHCI `1022:43eb`; no PS/2 controller and no UART; HPET and ACPI PM timer; an IOMMU; the video card's framebuffer BAR near 480GiB. Keyboards and mice there are full-speed devices, some behind high-speed hubs, which needs the transaction-translator path of xHCI that QEMU cannot exercise. `zig build usb-image` makes a stick that boots it to rio with no other disk; `docs/real-hardware.md` has the steps and what to look for.

**First boot on the machine, 2026-11-12: rio, with the network.** A stick written with `dd` from `967a959` booted to rio with nothing typed. (A first try through Ventoy reached the kernel, but Ventoy serves the image as a file, so once planZ drives USB itself it finds no Plan 9 partition; see `docs/real-hardware.md`.) The user's files from the checklist (`kmesg`, `pci -v`, `/dev/usb/ctl`, `sysstat`, `ndb`, one `ifstat`) show:
- 12 processors up (family 23 model 113, TSC 3594MHz by HPET), the self-test passed; 32696M of memory; both IOAPICs (gsi 0-23 and 24-55); the IOMMU's IVRS table present and untouched.
- The screen is the 800x600 mode the firmware left; `*gopmode=` was not set.
- USB, never run before on real controllers: both xHCI controllers (`1022:43ee`, 32-byte contexts, 31 scratchpad buffers; `1022:149c`, 64-byte contexts, 2), the root from a SuperSpeed stick (`usbroot: hjfs on /dev/sdUd301d/fs`), and a high-speed hub with transaction translators (`0424:2514`) with a full-speed Logitech receiver and a low-speed keyboard behind it. Keyboard and mouse work: rio's menu made a second window (checklist step 1).
- `ether8125` on the RTL8125B (macv `0x64100000`, rev 5), its first run on the chip: link at 1000Mbps, a DHCP lease, and `ip/ping` answered (step 2); 9 frames out and 230 in with no errors, interrupts arriving and none lost. Open: its `ifstat` shows `rcr 0x41020c0e` where the driver wants `0x41000c0e` (bit 17).
- Seen, not worked on: Intel 7265 Wi-Fi (`8086:095b`, no driver), the HDA controller `1022:1487` attached as `#A0` with a Realtek `10ec0897` codec, an Intel 760p NVMe drive (12 submit queues), AHCI.
- Still to do on the machine: sound (step 3, the audio plan's step 4: waits for a wired speaker), the Zig programs (step 4), a second `ifstat`, and the RTL8153 USB Ethernet adapter.

#### Audio (HDA): steps 1–3 done, step 4 waits for the machine
Port 9front's audio stack as it is configured in `9/pc64/pc64` (`audio` device, `audiohda` driver; `audiosb16` and `audioac97` stay out). Stock `termrc` already binds `#A` onto `/dev` when it exists, so `zuke`, `audio/wavdec`, `audio/mixfs` and the other stock programs need nothing more.

| New file | From | C lines |
|---|---|---|
| `port/audioif.zig` | `port/audioif.h` | 56 |
| `port/devaudio.zig` | `port/devaudio.c` | 508 |
| `port/audiohda.zig` | `pc/audiohda.c` | 2023 |

`audiohda` goes in `port/` like `ether8125` and `sdiahci`, since it uses only PCI, `vmap`, `xspanalloc` and `intrenable`. `conf/pc64.zig` gains `audiodevtab` ('A') and `audiohdalink()` in `links()`.

Steps, each one built and tested before the next:
1. **`audioif` and `devaudio`.** `Audio` keeps its function pointers; `waserror` in `audioopen`, `audioread`, `audiowrite` and `audioclose` becomes `errdefer`/`catch`. `Audiochan` is malloc'd as in C, so its 4001-byte buffer is not on the stack. Kept: the defaults written on first attach (`speed 44100`, `delay 1764`, volumes 100), `genaudiovolread` and `genaudiovolwrite`. With no card linked, the kernel still boots and `#A` fails with "no such device".
2. **`audiohda`, in the C's order.** First the controller reset, CORB/RIRB and `hdacmd`; then codec, function-group and widget enumeration, `findpath`, `connectpath` and the pin scoring; then the stream ring, the interrupt, read/write/close, volume, `audiostat` and `audioctl` (`pin`, `inpin`). Size checks: `findpath`'s queue is 2 KB on the stack and `Codec` is about 2 KB and malloc'd, both fine with 16K stacks. `hdastatus` writes into `Audiochan.buf`. Known DIFFs:
   - `hdacmd` is dropped: it is an `addarchfile` file, planZ has no `devarch`, and nothing in 9front's tree uses it.
   - MMIO goes through volatile pointers. `Sdctl` stays byte-accessed where the C uses `csr8`, because it is a 24-bit register.
   - `PCIWADDR` becomes `arch.paddr`.
   - `intrenable` gets MSI when the device offers it, as other planZ drivers do.

   To check against the HDA specification while porting: `Agetright` is `1<<15`. That is harmless for the output amplifier, but `getinamp`'s right channel then reads the *output* amplifier. If confirmed, fix it and note "Fixed from C".
3. **QEMU test, `zig build test-audio $D`.** QEMU runs with `-device intel-hda -device hda-duplex,audiodev=snd0 -audiodev wav,id=snd0,path=<scratch>/out.wav`. The guest mounts the FAT boot partition (as `test-usb` does), checks that `/dev/audiostat` lists a codec and an `outpath`, and plays a known tone with `audio/wavdec < tone.wav > /dev/audio`. The host then checks `out.wav`: not silent, the expected frequency, about the expected length. The guest also checks that:
   - `/dev/volume` reads back and accepts `master 50`;
   - a second open for writing fails with "device is busy";
   - reading `/dev/audio` returns data and does not hang (QEMU's line-in is silence).

   Run it with `ich9-intel-hda`, and with the `hda-output` and `hda-micro` codecs, so pin choice is exercised on more than one layout. Run it with 1, 4 and 8 processors and in a debug build.
4. **Real hardware: the motherboard's controller only, for now.** The board has two HDA controllers.
   - The target is the chipset's controller (`1022:1487`, Starship/Matisse, which 9front lists), which carries a Realtek ALC897 codec.
   - The RX 6500 XT's HDMI/DP audio (`1002:ab28`) is out of scope for now, but `hdamatch` would still match it by class `0403`. Linux shows no codec on it with the current monitor, so its probe would fail anyway. A monitor that takes audio would give it a codec, though, and then it could become an `#A` device.
   - `DIFF:` `hdamatch` therefore skips an HDA function whose device's function 0 is a display controller (PCI class 03), marked as temporary until GPU audio is wanted.
   - With that, the chipset controller is always `#A0`. Confirm it from the boot messages.
   - The checklist gains a step: save `/dev/audiostat` and `/dev/volume` to the FAT partition, play a file through the rear green jack, then try the front headphone jack with `echo pin N > /dev/audioctl`.
5. **Documentation.** Update the README status, `docs/hardware-checklist.md`, the M9 status row and the kept-and-dropped lists.

Risks: QEMU emulates only Intel's controller, so AMD controller quirks show up only on the machine. The ALC897's default pin configuration may not score the jack the user expects; `audioctl`'s `pin` command is the fallback. Recording is tested only against silence.

Progress: `port/audioif.zig`, `port/devaudio.zig` and `port/audiohda.zig` are ported, with the DIFFs listed in their headers. `zig build test-audio $D` (`tools/audiotest.sh`, `tools/audiocheck.py`):
- The guest reads `audiostat` and `volume`, sets `master` and `recgain`, and is refused a second open for writing ("device is busy").
- It fetches a 2-second 440 Hz tone from the host over HTTP and plays it with `audio/wavdec`.
- QEMU's wav back end records 1.96 s of it at 439.9 Hz on both channels.
- It passes with `intel-hda` and `ich9-intel-hda`; with the `hda-duplex`, `hda-output` and `hda-micro` codecs; with 1, 4 and 8 processors; and in a debug build.

Two checks were done by hand:
- **Graphics-card audio is skipped.** A QEMU VGA adapter at function 0 with an HDA controller at function 1 of the same slot is reported as "graphics card audio, not used", and a second controller elsewhere becomes `#A0`.
- **The `Agetright` fix.** It is confirmed against the HDA specification. With it, `recgain 30 70` reads back as `29 70`; the 29 is the C's rounding.

Not tested:
- Reading `/dev/audio`: QEMU's wav back end has no input.
- What becomes of the last 40 ms of the tone, which could be the driver or QEMU's recording.

Step 4's commands are in `docs/hardware-checklist.md` (section 3).

#### Minimal Zig libc: steps 1–6 done
The goal is a Zig library for planZ's own user programs that covers what 9front's `libc` gives a simple program, so Zig can replace C for new user programs. It is a Zig API (errors as error unions, slices instead of NUL-terminated strings where the kernel allows it), not a C ABI libc. Stock C programs keep using 9front's own libc.

**Why not Zig's `plan9` target.** In Zig 0.17, `-target x86_64-plan9` cannot write an executable ("UnsupportedObjectFormat"), and with `-ofmt=elf` `std/start.zig` fails to compile (it asks for `elf.AT.HWCAP`). `std.os.plan9` has only a handful of calls. The library therefore keeps today's method: freestanding x86_64, linked with `src/user/user.ld` into an a.out. If upstream fixes the target later, the library can become the `std.os.plan9` back end.

**Layout.** It goes in `src/user/lib/`, one module named `libc` with a file per area. `sys.zig` becomes its lowest layer. `build.zig`'s `addUserProgram` gives every user program the module. A new `zig build user` installs the programs in `zig-out/user/bin`, and test boots put that directory on the FAT partition.

Steps, each with a program that uses it:
1. **System calls, complete.** Every call in `libc/9syscall/sys.h` that the kernel serves. Added to today's set: `seek`, `remove`, `mount`, `unmount`, `fversion`, `fauth`, `wstat`, `fwstat`, `fstat`, `stat`, `segattach`, `segbrk`, `segfree`, `segflush`, `semacquire`, `tsemacquire`, `semrelease`, `nsec`, `noted`, `errstr`. Each has a raw form, as today, and a checked form returning `error.Plan9`, with the kernel's message kept per process for `errstr()`. The numbers and the Tos layout are checked against `std.os.plan9` where both exist.
2. **Start-up, from `amd64/main9.s` and `port/main.c`.**
   - `_start` saves `_tos` from RAX and reads argc/argv from the stack. It calls `main(args: []const []const u8)`, which may return `!void`.
   - A normal return calls `exits(nil)`. An error return calls `exits` with the error string.
   - `boot.zig`'s and `initcode.zig`'s own `_start` stay. `initcode` must fit in a page and uses only raw calls.
   - `main9p.s` (profiling) is not ported.
3. **Memory.** A `std.mem.Allocator` over `brk`, so `std.ArrayList`, `std.HashMap` and the rest work. First choice: reuse the kernel's `port/pool.zig`, the same pool library 9front's `malloc` uses. If it cannot be separated from kernel locks cleanly, use a small free-list allocator in its place. Allocator failure is `error.OutOfMemory`, not `sysfatal`.
4. **Formatted output.**
   - `print`, `fprint`, `sprint`, `seprint` and `sysfatal` on top of `src/lib/fmt.zig`, which already implements Plan 9's verbs.
   - A `std.Io.Writer` over a file descriptor, so Zig's own `{d}`/`{s}` formatting also works.
   - `%r` prints the last error string.
5. **Files.**
   - `Dir`, with `dirstat`, `dirfstat`, `dirwstat`, `dirfwstat` and `dirread`, using `convM2D` and `convD2M` from `src/lib/fcall.zig`.
   - `readn`, plus a buffered reader and writer (the role of `bio`, as `std.Io.Reader`/`Writer` over a descriptor) and `readline`.
6. **Processes and notes.**
   - `fork` and `rfork`; `exec` from a slice of arguments; `wait`, which parses `await`'s text into a `Waitmsg`.
   - `notify` with the stack trampoline `boot.zig` already has, `atnotify`, and `postnote`.
   - `getpid` from `_tos`.
   - Environment through `/env`: `getenv` and `putenv`.

**Proof programs.** `echo`, `cat`, `ls` and `wc` in Zig, plus `boot.zig` moved onto the library. A new step `zig build test-zuser $D` boots stock 9front, runs each Zig program and its stock counterpart on the same input, and compares the outputs.

**Not in this plan.** Locks for shared-memory processes (`Lock`, `QLock`, `rendezvous`), threads (`libthread`), a full `std.Io` implementation (`std.Io.File`, `std.process.Init`), dial and networking, and aarch64/riscv64 start-up code. Each is a later step once a program needs it.

Progress: the library is in `src/user/lib/` (module `libc`).
- **Files:** `sys.zig` (every call the kernel serves, with argument layouts taken from the kernel's handlers), `start.zig`, `malloc.zig` (the kernel's `pool.zig` over `brk`, plus a `std.mem.Allocator`), `dir.zig`, `proc.zig`, `string.zig` (`tokenize`, `cleanname`, rc quoting, `Args` for ARGBEGIN), `qsort.zig` (9front's algorithm step for step) and `libc.zig` (the checked calls, `print`/`fprint`/`sprint`/`sysfatal` on `src/lib/fmt.zig` with `%r`, and `FdWriter`/`FdReader` for `std.Io`).
- **Slices, not NUL-terminated strings (the user's rule).** Every string is a plain slice, and there is no sentinel-terminated type anywhere in `src/user`, `sys.zig` included: paths, `main(args: []const []const u8)`, `exits`, error strings, the environment.
  - **Outgoing.** Every call that takes a string uses planZ's slice system calls (below), so a slice goes to the kernel as (address, length) with no copy and no 0 after it.
  - **`exec`.** Its arguments go as an array of `sys.Str` pairs; `sys.exec` fills one the caller gives, `libc.exec` uses a stack array of 32 or allocates.
  - **Incoming.** Strings from the kernel (`argv`, a note's message) are read through `sys.span`; strings it wrote into a buffer of ours (`errstr`, `fd2path`) through the bounded `sys.upto0`.
  - **Tests.** `libctest` checks names and `exec` (see the slice system calls below).
- **Build.** A program is built with `src/user/lib/root.zig` as its root file and its own file as the module `program`. Zig analyses an imported file only as far as it is used, so this is where `_start` is exported and the panic handler is set. The panic handler prints `argv0: panic: msg` and exits with the message. `boot.zig` and `initcode.zig` stay their own roots and use `libc.sys` only; `initcode` is still one page with no data.

Proof programs in `src/user/cmd/`: `echo`, `cat`, `wc` and `ls`, each from its 9front C file, plus `libctest` (more below).
- `ls` has no `-l` or `-m` yet: they need `ctime`, the time zone and the `%M`/`%C` formats.
- `zig build user` installs them in `zig-out/user/bin`.
- `zig build test-zuser $D` (`tools/zusertest.sh`) fetches them into a booted stock 9front over HTTP and runs each beside the stock program with the same arguments. All 16 cases match byte for byte: standard output, and standard error for the failures.
- `ls -tr` matches only because the library's `qsort` is 9front's algorithm, since `ls` breaks ties by the entries' addresses while `qsort` moves them.
- `libctest` checks the rest of the library: containers on the allocator, a 4096-aligned allocation, the `Io.Writer`, `dirstat`/`dirfstat`, `%r` and `rerrstr`, `getenv`/`putenv`, `fork` and `wait` (with the kernel's "name pid: " in front of the exit message), an alarm note through `atnotify`, and `seek`.

Second batch of commands: `pwd`, `basename`, `cleanname`, `sleep`, `touch`, `tee`, `mkdir`, `rm`, `cmp`, `uniq`, `chmod`, `cp`, `mv` and `tail`, each from its 9front C file. `date` and `seq` wait for `ctime`/time zones and floating-point formatting.
- **Library additions.** `bio.zig` is the core of libbio: `Biobuf` with `init`/`term`/`flush`/`getc`/`ungetc`/`read`/`write`/`putc`/`rdline`/`linelen`/`print`, the C's buffer arithmetic kept, and writers flushed at exit. The rest: `atexit` (run by `exits`), `getwd`, `access`, `time`, `iounit`, `strtol`/`strtoul` returning how much they consumed, and `basename`.
- **One shared check script.** `tools/usbzig.rc` is now the only one: the stick's `zig/run`, and what `test-zuser` fetches and runs. It compares outputs, exit statuses (without "name pid: ") and error messages with the stock programs. For `mkdir`, `touch`, `chmod`, `cp`, `mv`, `rm` and `tee` it runs one sequence of operations in two directories, one per set of programs, and compares mode, length and name of everything left.
- **Result.** All 22 comparisons are byte-identical, and `libctest` passes. On a difference it prints the first lines of `diff`.
- **Fixed from C, in `cleanname`.** The C cleans names in place in `argv`, so cleaning `''` writes ".\0" into a one-byte string and turns the next argument into "": `cleanname '' ../../a` prints "." twice. The Zig version copies each name.

Third batch: `mtime`, `strings`, `freq`, `comm`, `read`, `unicode`, `tr`, `xd`, `split`, `du` and `test`, each from its 9front C file.
- **Library additions.** `rune.zig` ports libc's `rune.c` (`chartorune`, `runetochar`, `fullrune`, `runelen`) plus `utflen` and `utfrune`: Plan 9 decodes surrogates where Zig's `std.unicode` refuses them, and the outputs must match byte for byte. `bio.zig` gains `getrune`/`ungetrune`/`putrune`, `offset_` (Boffset), `seek`, `open` (Bopen; `term` closes what it opened) and `setiofn` (Biofn). `strtol32`/`strtoul32` are Plan 9's on amd64, where `long` is 32 bits and an overflow clamps.
- **`fmt.zig` (shared with the kernel).** `%C` encodes as `runetochar` does (surrogates included, past 0x10FFFF as Runeerror). `%q` takes a `doquote` hook, which user start-up sets to `needsrcquote` as 9front's libc does, so names with rc's special characters are quoted; the kernel leaves it null.
- **Not ported yet.** `du -e`/`-h` need `%g`; they print that and exit. (`split -e`, `-i`, `-x` came with the libregexp port, below.)
- **Kept from C.** `split` closes standard input when it opens its first output file (its descriptor starts at 0), and says "grep" when it cannot create one. `comm` compares lines as signed bytes and drops a last line without a newline.
- **Check script.** The new commands' cases run with stderr folded in and `/tmp/zig/` cut on both sides, since `sysfatal` and some usage messages print `argv0`. `split` is in the file-operations sequence, so the files it makes are compared too. Each "same" line now gives the output's size, which shows the cases are not empty. All 33 comparisons match and `libctest` passes.
- **Test harness.** `zusertest.sh` now has the guest fetch the program names from a file: the typed command with 30 names was about 380 characters, and one run lost a character in the middle of it.
- **The lost character: 9front's `kbdfs`, not the kernel.** Typing 15 known 363-byte lines into `cat` under rio, with planZ and with stock 9front's `9pc64` (booted by its own UEFI loader from the ISO) on the same QEMU machine and disk: both lost byte 256 of every line, and both now and then lost the first character of a line (planZ 2 of 15, stock 5 of 15); the serial port counted no overruns. The original lost `9` was byte 256 of the typed command. `kbdfs`'s `lineproc` cooks a line in a 256-rune buffer, and its main loop gives it each rune with `nbsend` on an unbuffered channel, which drops the rune when `lineproc` is not waiting: always right after the buffer fills (it is sending the chunk on), sometimes right after a newline. `bootchat.sh` now refuses any typed line of 256 bytes or more, with that explanation.

Found while testing it and fixed: once in about 8 boots under TCG the kernel panicked with `sched: no process` as hjfs started.
- **Cause.** `proc.sched()` read `arch.m()` with interrupts on and only then read `mach.proc` through it. The `randomseed` kproc, which calls `sched()` in a loop, could be preempted between the two reads and resume on another processor holding the old one's `Mach`. That gave nil there if the old processor was idle, another process if it was busy, or a wrong `ilockdepth`.
- **Fix.** `sched()` now takes `up` from `arch.up()`, one `%gs` load, and reads `m` with interrupts off. `qlock.zig`'s `checklocks` reads `ilockdepth` the same way.
- **Check.** A 1 ms delay was put between the two reads, temporarily. The old code then panicked in 6 of 14 TCG boots (`sched: no process` and `cpu3: ilockdepth 0`); the fixed code panicked in none of 14.
- **Other uses of `arch.m().x` from process context.** They are statistics counters or a CPU number used as a hint, as in the C.

#### System calls that take slices: done
planZ's own extension, with no 9front counterpart. 9front's calls take names as addresses of bytes ending in a 0, so `sys.zig` copies each slice into a stack buffer to add the 0, refuses names of 1024 bytes or more, and makes `exec` lay out a C argument array. A second set of calls takes each string as a (pointer, length) pair instead. It is for planZ's Zig programs only: 9front's calls stay, unchanged, for stock C binaries, and 9front's libc never uses the new ones.

**The kernel is already mostly done.** Inside it, names are slices (`namec`, `validname`, ...); the one place a 0-terminated string becomes a slice is `fault.userstr`. A new handler is the old one with `fault.userslice(addr, len, false)` in place of `userstr`, plus a length check. A 0 byte inside a name is refused by `validname`, since 0 is one of the characters `isfrog` rejects.

**The interface.**
- **A string is two consecutive argument words, pointer then length.** The kernel reads arguments as 8-byte words from the user stack, so this is also exactly what a C struct `{ptr, len}` passed by value gives on 6c (and on SysV, in two registers). The interface is documented as two words, so it depends on no compiler's struct-passing rules, and a caller may use either form.
- **Arrays of strings (exec's arguments) are an array of 16-byte pairs**, `{ptr: u64, len: u64}`: an `extern struct` in Zig (a Zig slice's own layout is not guaranteed), two 8-byte fields in C (not `ulong`, which is 32 bits on 9front). The array is passed by address with a count. The kernel checks the array, copies it into kernel memory once, and works only from the copy, so another process sharing the memory cannot change a pair between the check and the use.
- **No struct passed by address for a single string.** It would add a second validation, a copy-in and the same check/use race for no gain.
- **Zig wrappers take `[]const u8` and `[]const []const u8`**, so programs never see the split.

**Numbers.** 9front uses 0–53. The new calls start at 64, leaving 9front room to grow, and `nsyscall` grows to match.

| New call | Arguments | Replaces |
|---|---|---|
| `open`, `create`, `remove`, `chdir` | name (ptr, len), then the old arguments | 1 string |
| `stat`, `wstat` | name (ptr, len), buffer, buffer length | 1 string |
| `bind` | new (ptr, len), old (ptr, len), flag | 2 strings |
| `mount` | fd, afd, old (ptr, len), flag, spec (ptr, len) | 2 strings |
| `unmount` | name (ptr, len; length 0 for none), old (ptr, len) | 2 strings |
| `segattach` | attr, class (ptr, len), va, len | 1 string |
| `exits` | message (ptr, len) | scans for the 0, up to ERRMAX |
| `exec` | file (ptr, len), pairs array address, count | NUL strings in a nil-ended argv |

Limits: names under 2^16 bytes (what 9P can carry, as `validname` checks today); the `exits` message is cut to ERRMAX as now. The calls that already take a buffer and length (`read`, `write`, `pread`, `pwrite`, `fd2path`, `errstr`, `await`) are not duplicated.

**exec.** The kernel validates the pairs array and each slice in it, replacing the `vmemchr` scan in `sysexec`. The new process's stack keeps the C layout (argv of 0-terminated strings), because a Zig program may exec a stock C one such as `rc` and the kernel cannot tell which kind it is starting. So `start.zig` still turns argv into slices with `sys.span`. Giving Zig programs a stack with lengths would need a marker in the a.out header; not in this plan. The `#!` path in `sysexec` works on its own copies and is unaffected.

**User space.** `sys.zig` passes `s.ptr, s.len` straight through: `sys.Name`, its 1024-byte limit and the copy go, and `sys.exec` needs no caller buffer (a small stack array of pairs, or the allocator in `libc.exec` past that). `initcode` should shrink back toward its earlier ~800 bytes. `sys.span` stays for argv and notes, `sys.upto0` for `errstr`/`fd2path`.

**Tests.**
- `libctest`: a 0 byte in a name is refused (now by the kernel); a name over 1024 bytes now works and one of 2^16 is refused; a 0-length name; `exec` with an empty argument and one with spaces; a bad pointer in exec's pairs array gives an error, not a crash.
- `test-9front` shows the old calls still serve stock binaries; `test-boot`, `test-zuser` and `test-usb` as now.
- A DIFF note in `syscall.zig` and on each new handler.

Progress: done, with one call more than the table: `fauth` also takes a name, so it has a slice form too (`FAUTHN`, 76).
- **Kernel.** `fault.userstrn` turns (address, length) into a slice of user memory, refusing 2^16 bytes or more before touching memory, and returning an empty slice for length 0 without checking the address (namec then says "empty file name"). Each old handler became a wrapper over a body that takes the name as a slice; the new handler reads two words instead. `bindmount` takes its three strings as a small `Ustr` (address, optional length), read only where the C reads them. `MAXSYSARG` is 7, for the slice `mount`.
- **exec.** `sysexecn` checks the count and alignment, copies the pairs into kernel memory (`newslice`, so a huge count is `Enomem`, not a wait) and calls the same body as `sysexec` with a `Uargs` union. The two argument loops have a branch each; the pairs branch copies each argument onto the new stack and refuses a 0 byte in the copy, which no other process can change. `#!` drops the first pair as it drops `argv[0]`.
- **exits.** `sysexitsn` copies at most ERRMAX-1 bytes and cuts at a 0 byte, as 9front's `exits` reads the message.
- **User space.** `sys.Name`, `argvsize` and `execaddrs` are gone; `call` takes a tuple of up to seven words. `initcode` makes its `Str` array from the kernel's argv with `span` (the word below argv is a 0 return address, not argc) and is 1.5 KB of text, down from 2.5 KB.
- **Tests.** `libctest`: a 0 byte in a name ("bad character"), an empty name ("empty file name"), a name passed as a slice of a longer string, a 3009-byte name that opens `/dev/cons`, a 2^16-byte name ("name too long"), an `exec` argument with a 0 byte ("bad arg"), and an `exec` with a bad address in its pairs, which kills the child with "sys: bad address in syscall" as any bad address in a system call does. `test-boot`, `test-9front`, `test-zuser`, `test-usb`, `test` and `check-ports` pass.
- **Copy, then check (fixed from C).** `validname` with a copy now copies the name first and checks the copy; the C checks user memory and copies after, so a process sharing the memory could slip a control character into the kernel's copy. The `wstat` calls copy the stat buffer into the kernel (`kstat`) and both `validstat` and the device use that copy, where the C checks user memory and lets the device read it again. `validstat` now checks the name in place at any length (the C copied it into 64 bytes and let longer names through unchecked); `libctest` renames to an 80-byte name with a control character, which the kernel refuses ("bad character"; with the old check the file server answered "invalid operation"). `sysexitsn` no longer copies the message, since `pexit` copies it before freeing memory.

#### libregexp port: done
9front's `libregexp` (1,247 lines: `regcomp.c` 568, `regexec.c`/`rregexec.c` 189/185, `regsub.c`/`rregsub.c` 66/66, `regerror.c` 15, `regprint.c` 66) is a lexer, a recursive-descent parser, a class builder, a compiler to instructions and a Pike VM matcher (all threads in step, one rune at a time). It needs nothing beyond libc. Its users: `sed`, `ed`, `split -e`, `calendar`, `awk`'s regular expressions and plumbing (9front's `grep` has its own compiler and does not use it). `sed` and `ed` supply their own `regerror`.

**Interface: slices and offsets.**
- `Resub` is two offsets into the subject, `sp: ?usize, ep: ?usize`, not pointers.
- `regexec(prog, str: []const u8, sem: ?[]Resub) bool` never writes to the subject. The C bounds a search by writing a 0 at `sem[0].ep` and putting the byte back; the port bounds it by the offset and keeps the C's rule that `$` matches only at the real end, not at that bound.
- **Open decision, recommended yes:** a 0 byte inside the subject ends it, as in C, so results match stock on binary input (a DIFF).
- The byte and rune matchers (`regexec`, `rregexec`) are one function generic over `u8` and `Rune`; so are `regsub` and `rregsub`. `regsub` takes the subject too, since `Resub` holds offsets, writes into a `dst` slice and returns the part used, cutting where the C does.
- `regcomp(allocator, str)`, `regcomplit`, `regcompnl` return a `*Reprog` owning its instructions and threads, freed with `deinit`.
- Errors: `regcomp` returns `error.Regexp` with the C's message (`regexp %s: syntax error: %C`, `Malformed class`, `Class too big`, …) in a buffer. `regerror(msg)` keeps the default: print "regerror: …" and exit "regerr". Programs with their own handling (sed, ed) do it themselves.
- Limits kept: 32 subexpressions, 200 ranges in a class, threads sized to the pattern's length plus one (running out panics, as the C asserts).
- `src/user/lib/regexp.zig`, reached as `libc.regexp` (planned as a module of its own; inside libc it costs nothing, since Zig analyses only what a program uses, and the file still builds alone for the host tests). It uses only `rune.zig`, `qsort.zig` and an allocator, so it also runs as host unit tests.

**Inside: Zig's types in place of the C's codes, unions and gotos.** Behaviour, messages and results stay the C's; only the representation changes.
- **Tokens are a tagged union**, `union(enum) { any, bol, eol, end, lpar, rpar, alt, rep: enum { star, plus, ques }, rune: Rune, class: Class }`. The C's `lex()` returns an int and leaves the rune, the negation flag and a 402-entry pair buffer in side fields; its peek flag becomes a one-token lookahead.
- **Parse nodes are a tagged union** (`cat`, `alt`, `star`, `plus`, `ques`, `sub`, `class`, `rune`, `any`, `notnl`, `bol`, `eol`), each with only its own fields, in a slice sized as the C sizes its node pool.
- **Instructions are a tagged union**, `union(enum) { rune: Rune, any, notnl, bol, eol, class: struct { lo: Rune, hi: Rune, next: u32 }, split: struct { a: u32, b: u32 }, jmp: u32, save: u8, unsave: u8 }`, with jumps as indices. Switches over them are exhaustive, where the C has `default: abort()`.
- **The matcher uses labeled `switch` with `continue`**: the C's `Again`, `Switch`, `Done` and `Class` labels become states and each `goto` a `continue :vm .state`, so the port reads line for line against `regexec.c`. Thread lists are indices into the thread array.
- **Errors propagate as Zig errors** where the C `longjmp`s out of the parser.
- **Compile-time patterns.** The same compiler code runs at comptime for a literal pattern, `comptime regexp.compile("^[a-z_][a-z0-9_]*$")`: a program in read-only data with no allocation, and a bad pattern fails the build with the C's message. For that the compiler fills buffers the caller provides; the C already counts instructions while parsing, which becomes a sizing pass. The runtime `regcomp` sizes the buffers from the allocator. Long patterns may need `@setEvalBranchQuota`.
- `regprint`'s listing becomes the program's `fmt9`, as `reprogfmt` is a format in C.
- **Later, not in this plan:** a matcher specialized per comptime pattern (the instruction list unrolled into code with `inline`), much faster; the plain matcher, which must match the C, comes first.

Steps:
1. **The library and host unit tests**: literals, `.`, `^`, `$`, classes and negated classes (with their newline rule), `* + ?`, alternation, groups and submatches, start and end offsets in `sem[0]`, every compile error, `regsub` truncation, the rune versions, and the comptime path on the same patterns.
2. **Differential test against stock libregexp in the guest.** The 9front image has `6c`/`6l` (to be checked, with `/sys/include`), so `tools/retest.c` is compiled there against the real library, and a Zig `retest` reads the same table, `tools/retest.txt` (a few hundred `pattern<TAB>subject` lines, bad patterns included). Each prints, per line, the result, the submatch offsets, a `regsub` result and any compile error; the outputs must match byte for byte. It runs from `usbzig.rc` like the command comparisons. Without a compiler in the image, this falls back to comparing `sed` with stock.
3. **`split -e`, `-i`, `-x`**, compared with stock in the file-operations sequence.
4. **`sed`** (1,473 lines) as the real user of the library, compared with stock over a set of scripts: a batch of its own.

Estimate: about 900 lines of Zig with tests for steps 1–3.

Progress, steps 1–3:
- **Library.** `regexp.zig` as planned: tagged unions for tokens, nodes and instructions; the matcher a labeled switch whose states are the C's labels; `Static(pattern, opts)` compiles at build time (a bad pattern fails the build with the C's message); `libc.regerror` is the default handler. 14 host unit tests, including the comptime path producing the same instructions as the runtime one.
- **Found in the C, kept:** nothing after the pattern is checked, so `a)` compiles and matches `a`.
- **Fixed from C.** `regcomp` mallocs the program and never sets the instructions' generations, and `regexec` clears them only when the first one is not 0, so with stale heap memory the first match after a compile can skip instructions and miss: the stock library reported no match for `(a*)+` on an empty line after other programs had been freed, and matched it in a fresh process. The port zeroes them. `retest` makes one throwaway match after each compile on both sides, so the comparison measures the matcher and not the heap.
- **Differential test.** `tools/retest.c` is built in the guest with the image's `6c`/`6l` against stock `libregexp.a`; `src/user/cmd/retest.zig` prints the same lines. `tools/retest.txt` (1,570 lines: 63 patterns × 23 subjects, 24 bad patterns, `regcompnl` and `regcomplit` cases, UTF-8, invalid bytes, embedded 0, classes at the 200-range limit) gives every match of a left-to-right scan with subexpressions and a `regsub`, a match bounded at half the subject, and the rune versions. All 146,971 bytes are the same.
- **Found by it, in `fmt.zig` (shared with the kernel).** `%s` now copies as 9front's `_fmtcpy` does: each rune is decoded and encoded again, so a byte that is not UTF-8 prints as Runeerror, and an incomplete sequence near the end (fewer than 4 bytes left and not a full rune) ends the output. Width and precision count runes as `chartorune` decodes them.
- **`split -e`, `-i`, `-x`** done; the file-operations sequence covers splitting at a match, `-x`, naming files from subexpression 1 with `-s`, `-i`, and bad patterns (the default `regerror`).

Step 4, `sed` (`src/user/cmd/sed.zig`, 1,370 lines from 1,473): the pattern space, hold space, work buffer and text pool are rune arrays with lengths; commands, labels and pending appends are indices; a script line is read through an accessor that gives 0 past its end, where the C reads its terminator. Kept from the C: `c` prints on a range's first line only (never with no address), `N` at the end of the input deletes the pattern space unprinted, `P` and `s///P` write each rune's low byte, `s///P` with a w file skips the file, w files are appended to, an empty w name is standard output, labels are at most 7 runes (b/t labels run to `;`). DIFFs: a w file name is cut at 39 bytes (the C overruns `fname[40]`), a y whose source has an escape other than `\n` past the table is "garbled" (the C writes past it), and a pattern stops 4 bytes short of the C's 512-byte limit. `usbzig.rc` compares about 90 sed runs with stock (addresses and ranges, every command, substitution flags and groups, empty matches, labels, `a`/`i`/`c` text, `-n`/`-g`/`-e`/`-f`, standard input, several files, and 21 error cases) and, in the file-operations sequence, the files `w` and `s///w` write: all the same.

#### Floating-point formatting: done
9front formats `%e %f %g %E %G` with `xdtoa` in `libc/fmt/fltfmt.c` (323 lines). It guesses 17 significant digits from `frexp` and a 160-entry `pow10` table, tries rounding away trailing 9s, then converts the digits back with `strtod` and steps the last digit up or down until the result equals the number; then it pads, rounds and strips per verb (`NaN`, `Inf`, precision at most 30, and only width and `-` kept from the flags, so `%05.2f` pads with spaces). Which 17 digits it settles on depends on the guess and on `strtod`, so matching it byte for byte means porting `xdtoa`, `pow10`, `frexp` and `strtod` exactly, not using Zig's float printing or parsing.

Steps:
1. **`strtod`**, `src/lib/strtod.zig` from `port/strtod.c` (526 lines): multi-precision arithmetic on the decimal digits, the closest double with ties to even, its own syntax and limits (1,500 digits, exponents near 310), with `NaN`/`Inf`/`isNaN`/`isInf` from `nan.c`. Pure code, for `fmt.zig`, libc's `strtod`/`atof` and host tests. Host tests check it against Zig's correctly rounded parser on many generated decimal strings (halfway cases, subnormals, overflow); where they disagree the C counts, with a note.
2. **The float verbs in `fmt.zig`**, from `fltfmt.c`: `xdtoa`, `xadd`, `xsub` and the `pow10` table exactly (down to `e * .301029995664` truncating to an int), printed through the `%s` copy as `_floatfmt` does. Arguments `f64`, `f32` or comptime floats. The kernel is unaffected: it prints no floats, and verbs that are not used are not compiled. Host tests: fixed cases, and `%.17g` reading back to the same value.
3. **Formats chosen at run time.** `seq` builds its format at run time and takes one from the user (`-f`), and `fmt.zig` parses formats only at compile time. A run-time interpreter, `fmt.runprint(format, values)`, takes tagged values (integer, float, string) and calls the same verb code with flags, width and precision parsed at run time, for every verb (so `xd`'s switch over its format table can go later). A verb that does not fit its value's type, undefined in C, prints a marker such as `%!f(string)`: a DIFF.
4. **The math the commands need**, in libc: `atof`, `strtod`, and `frexp`, `ldexp`, `modf`, `pow10`, `fabs`, `floor`/`ceil`, `fmod` from `port/*.c`; `sqrt` is the SSE instruction on amd64, the same as Zig's `@sqrt`.
5. **Differential test in the guest**, like `retest`: `tools/fltest.c` built with `6c` against stock libc, and a Zig `fltest` printing the same lines. Both generate the same doubles from the same small PRNG (about 20,000 bit patterns) plus ±0, subnormals, the largest and smallest normals, powers of 10, values next to rounding boundaries, NaN and ±Inf, through a set of formats (`%g %.17g %e %.0e %f %.30f %#g %+e % f %-12.3E` …), and `strtod` over generated decimal strings with the result's bits in hex. Byte for byte.
6. **The commands**: `du -e`/`-h`, `seq`, `factor` and `primes`, compared with stock in `usbzig.rc` (including `seq -w`, `seq -f` with several formats, and `factor` on large numbers).

Estimate: about 1,100 lines of Zig with tests, `strtod` the largest part, plus the four commands.

Progress, all six steps:
- **`src/lib/flt.zig`**: `strtod`, `ldexp`, `frexp`, `modf`, `pow10`, `floor`/`ceil`, `fmod`, `fabs`, `sqrt` and the NaN/Inf functions, reached as `fmt.flt` and from libc. The digit routines work from lengths; the digit buffer is 4096 bytes where the C's 1500 can overflow. On 10,000 random inputs the ported `strtod` agrees with Zig's correctly rounded parser everywhere.
- **`fmt.zig`**: `%e %f %g %E %G` from `fltfmt.c`, and `runprint`/`runsnprint` for formats known only at run time (one parser for both). Kept from the C: halves round up on the decimal digits (`%.1f` of 2.25 is `2.3`), the 9s step prints `%.17g` of 0.1 as `0.1`, and only width and `-` survive (`%05.1f` pads with spaces).
- **Differential test.** `tools/fltest.c` (built in the guest against stock libc) and `src/user/cmd/fltest.zig` print 38 edge values, 10,000 random bit patterns and 2,000 halfway cases through 16 formats, and `strtod` over 10,046 strings: all 7.7MB the same.
- **Found in the C.** (1) `_floatfmt`'s buffer is `1+308+1+30+1` bytes, but numbers of 1e308 and up have 309 integer digits: `%.30f` of one at or below -1e308 writes its 0 a byte past the end, and stock `fltest` faulted there (nil read), on the stock kernel too. The Zig buffer needs no 0, so it prints the whole 341 characters: Fixed from C. Both `fltest`s skip that one field. (2) 6c's code takes `NaN <= x` as true; `fltest.c` tests `isNaN` first. (3) Not explained yet: the first version of `fltest.c` printed each line with one `Bprint` of 17 values, and stock faulted (nil read, pc 0x202c03) while printing line 2619 (-1.04e49), on both kernels, 42 lines before the first value the overflow above touches. Formatting each field with `snprint` and writing it avoids it; the cause, in stock libbio or libc's fmt, is still to be found.
- **Commands.** `seq` (its format built or given at run time, through `runsnprint`), `factor`, `primes`, and `du -e`/`-h` (kept: a value past the "Y" prefix prints `<nil>`, as the C's nil-ended table does). All compared with stock in `usbzig.rc`.

#### grep: done
9front's `grep` (`cmd/grep`, 1,250 lines) does not use libregexp. `grep.y` (236 lines) is a yacc grammar and lexer: `* + ? | ( ) ^ $ .`, classes, and a newline as an alternative with the lowest precedence. `sub.c` (325) allocates nodes from `sbrk`, builds the graph, and has `addcase`, which turns an alternation of 7 or more characters into a 256-way table. `comp.c` (287) turns classes into UTF-8 byte ranges and builds a DFA lazily: `increment` makes a state the first time a byte reaches it. `main.c` (260) holds the flags and a byte loop over a 16K+16K buffer, written twice (plain and `-i`). It matches bytes, not runes, through one `next[256]` per state; that is why it is fast, and why it differs from libregexp on bytes that are not UTF-8.

Kept from the C, so the output matches:
- **Patterns.** A leading `*` makes the rest of that pattern line literal. A newline in a pattern, or between the lines of a `-f` file, is an alternative. `-e` may repeat and combine with `-f`; all are or-ed. A multibyte character outside a class is matched as its bytes.
- **`-i`** folds ASCII only, in the pattern (classes too: `[A-Z]` becomes `[a-z]`) and in the input.
- **Output.** `-n` prints `N: ` (a space after the colon). File names are printed with more than one file (`/dev/null` forces it); `-h` stops them. Output is flushed every 512 lines, and every line with `-b` or on standard input.
- **Input.** A last line without a newline still matches and prints without one, unless file names are shown. A line longer than 16K prints only its last 16–32K.
- **Exit statuses and messages:** `no matches`, `syntax`, `usage`, `open`; `grep: internal error: class too big` past 100 ranges in a class.
- **Class quirks, to confirm against stock.** The C uses the byte range `0xff`–`0xff` as "matches nothing", made when a negated class has adjacent ranges (`[^ab]`) or contains the largest rune, so `[^ab]` matches a raw `0xff` byte where `[^a]` does not. Bytes that are not UTF-8 never match `.` or a class.

Suspected in the C, to confirm in the guest:
1. A pattern ending in `\` (`grep 'a\'`): `getrec` has already stepped past the string's 0, so lexing continues in whatever memory follows (probably the next argument). If stock shows it, the Zig stops at the end: Fixed from C.
2. `follow` is sized from the node count before `addcase` adds nodes, but `fol1`'s bound uses the grown count. Possibly safe (each visit adds at most one entry); the port either shows it is or sizes `follow` after `addcase`.

Design:
- **Tokens** are a tagged union, `union(enum) { char: u8, class: []const u8, lparen, rparen, alt, star, plus, ques, begin, end, dot, newline, bad, eof }`. The lexer is a struct with the literal mode and reads the pattern through an accessor that gives 0 past its end: a slice, no sentinel.
- **Parser.** Recursive descent instead of yacc, one function per grammar level (`expr`, `expr0` … `expr4`). It must accept and reject exactly what stock's yacc parser does, including when the literal mode of a leading `*` begins; the error cases in the tests check this.
- **Nodes** are a tagged union, `union(enum) { alt, or_, begin, end, class: struct { lo, hi }, case: *[256]?u32 }`, with `next` as a `u32` index. Switches are exhaustive.
- **States** hold `next: [256]?u32`, the match flag and a sorted slice of node indices, found through the C's binary tree ordered by index instead of by pointer.
- **Memory.** An arena replaces `mal`/`sbrk`; as in C nothing is freed.
- **The search loop** is one `inline fn` with a `comptime fold: bool`, called twice, in place of the C's two copies.
- Left out: the `-1` graph dump (`reprint`), which stock cannot reach because `1` is not in its valid flags.

Steps, each tested before the next:
1. **Lexer, parser, nodes.** Host tests: accepted patterns, `syntax`, `empty pattern`, unterminated classes, a leading `*`, newlines.
2. **Classes to byte ranges** (`rclass`, `re2class`). Host test: for random rune ranges, the byte sequences accept exactly the encodings of those runes (against `rune.zig`), and the `0xff` quirk.
3. **`addcase`, `fol1`, `increment`: the DFA.** Host differential test: random patterns over a small alphabet and random lines, match or not, against the libregexp port (allowing for `.` not matching newline and for `^`/`$`).
4. **`main` and the search loop**: flags, buffering, a missing last newline, long lines.
5. **Comparison with stock in `usbzig.rc`**, output and exit status: every flag and mixes; one file, several, standard input, `/dev/null`; repeated `-e`, multi-line `-f`, `-e` with `-f`; newline alternatives and a leading `*`; classes with 2-, 3- and 4-byte runes, negated classes and ranges; `-i`; an empty file and one without a last newline; lines just under and over 16K and 32K; binary input with 0 and `0xff` bytes and bad UTF-8; errors (empty pattern, syntax, unterminated class, class too big, unopenable file, missing arguments, the trailing `\`); and stock's `g` script running the Zig `grep`.
6. Optional: timing over a large file, stock against Zig, as in `kbench`.

Estimate: about 900 lines of Zig with tests.

Progress, steps 1–5 (step 6, timing, not done):
- **`src/user/cmd/grep/re.zig`** (the lexer, recursive-descent parser, graph, classes and DFA; 740 lines, then the host tests) and **`src/user/cmd/grep.zig`** (main and the byte loop, 260 lines). States are arena pointers with `next: [256]?*State`, as in C; nodes are a tagged union linked by index. The parser gives "empty pattern" for any first token that cannot start an expression (yacc's first state reduces the empty program by default), so `grep ')'` and `grep '[abc'` say "empty pattern", as stock does.
- **Host tests** (`zig build test`): the grammar and its messages, "class too big" at 100 entries and "class too long", 300 random rune ranges as classes and negated classes against the runes' encodings, and 3,000 random patterns (alternatives by `|` and newline, groups, `* + ?`, classes, `^`/`$`) each over 200 lines in one run, against a backtracking matcher.
- **In the guest** (`usbzig.rc`): about 150 grep runs compared with stock, output and exit status, all the same (200,420 bytes), and stock's `g` script running each grep (same).
- **Found in the C, both Fixed from C** and checked in `usbzig.rc` against what is right (stock's output is printed beside):
  1. The trailing `\`, confirmed: stock `grep 'a' '('` reads on into the next argument and fails with "syntax error"; the Zig's pattern ends there, as plain `a` would.
  2. **The generation wraps.** Nodes are marked visited with a `ushort` generation, one more per new DFA transition; after 65536 transitions a node last visited exactly that many before looks visited and is skipped. `tools/grepwrap.zig` (run on the host by `build.zig`) drives the port, which makes the C's transitions in the C's order, to build a pattern ("zz", or `a` and 15 of `(a|b)`) and a 322K input where that happens on the last line: stock prints 5,267 lines and misses line 8168, which ends in "zz"; awk finds 5,268. The Zig's generation is 32 bits.
- The `follow` bound (suspicion 2) is kept as the C's check over a list that grows, so the port is safe either way; whether the C's array can overflow was not settled.
- Kept from the C and tested: `[^ab]` matches a raw 0xff byte where `[^a]` does not; `.` and classes never match bytes that are not UTF-8; `x^` matches a line after one ending in x; `-f` before `-e` makes the `-e` read the (finished) file, so it fails with "empty pattern".
- Seen while testing, not from grep: during `usbzig.rc`'s sed cases the guest printed `rc: can't open: file does not exist: '/env//tmp'` outside every compared output. Found in rc step 7: the case `$p^sed = $u` had a bare `=`, so rc took it for an assignment to a variable named `/tmp/zig/sed` (`sed` on the stock side), which it could not write to `/env`, and `sed =` never ran. It is quoted now.

#### rc: done (steps 1–7)
9front's `rc` (`cmd/rc`) is 5,939 lines; without `unix.c` (420) and the Unix `#ifdef`s, about 5,500. The lexer, grammar and syntax tree are `lex.c`, `syn.y` (yacc, with precedence) and `tree.c` (720 lines). The compiler to threaded code is `code.c` and `pfnc.c` (625). `pcmd.c` (169) prints a tree back as rc text. The interpreter is `exec.c`, `simple.c` (the builtins `cd`, `whatis`, `eval`, `exec`, `exit`, `shift`, `wait`, `.`, `flag`), `var.c`, `subr.c` and `trap.c` (1,940). Globbing, here documents and rc's own buffered I/O and `pfmt` are `glob.c`, `here.c` and `io.c` (700); `getflags.c` (234) parses its flags; `plan9.c` and `havefork.c` (735) are the system interface, with the builtins `rfork` and `finit`.

What constrains the port:
- **Functions travel as text.** A function is printed back as rc source (`fnstr`, through `pcmd`) and written to `/env/fn#name`; every child rc, stock or Zig, reads it there, and `whatis` prints the same text. The printer must match stock byte for byte.
- **The parser and the lexer feed each other.** Grammar actions change lexer state: `skipnl()` in the middle of rules, `lex->lastword=1` on keywords, `readhere()` after each newline. When the parser reads its next token therefore matters.
- **libc has what rc needs:** `fork`/`rfork`, `wait`, slice `exec`, `pipe`, `dup`, `notify`/`noted`/`atnotify`, `dirread`, `fd2path`, `access`, `rerrstr`; `/env` is read and written as files. Anything missing turns up while porting `plan9.c`.

**The parser: stock yacc's tables and yacc's driver in Zig.** A hand-written parser would have to call the lexer exactly when yacc does, for every `skipnl`, `lastword`, here document and `if not`; for this grammar that is too risky. Instead, 9front's own `yacc -d syn.y` is run once in the guest, a small host tool converts the arrays of `y.tab.c` into a Zig file, committed with a header saying how it was made, and `yaccpar` (about 150 lines) is ported to Zig with the grammar's actions as a `switch` on the rule number. Behaviour is the same by construction: the same lookahead and the same syntax errors. The same driver later serves `awk`, `hoc`, `bc` and `units`. Not chosen: porting yacc itself to Zig (about 2,900 lines of C) as a host tool; worth doing for `awk`, when these tables become its check.

Design:
- **Instructions** are a tagged union with their operands inside (`jump: u32`, `word: []const u8`, `mark`, `pipe: struct { fd0, fd1, jump }` …) where the C's code vectors mix function pointers, integers and strings in one union. Code vectors keep the C's reference counts. The interpreter is a switch over the instruction.
- **Strings** are slices. rc's glob marker, the byte 0x01, stays in them as in C, and so does `/env`'s list format of words ended by 0 bytes.
- **I/O.** rc's `io` buffers and `pfmt` are ported with their verbs (`%q`/`%Q` quoting, `%t` trees, `%v`, `%r`, `%p`); output must match stock exactly.
- **Memory.** Explicit frees with the C's reference counts on libc's allocator, since an interactive shell runs indefinitely; a debug count of live allocations after each command catches leaks.
- Left out: `unix.c` and the `#ifdef` branches. As usual, `// from` headers, `DIFF:` notes, and bugs found in the C are "Fixed from C".

Steps, each tested before the next:
1. **I/O, `pfmt`, the lexer and the tree.** Host tests on tokens: free carets, quoting, `$#`, `$"`, comments, the token-length limit.
2. **The parser** (the tables, the driver and the actions) and the printer (`pcmd`, `fnstr`). Host test: parse the 135 scripts in 9front's `rc/bin` and `rcmain`, print each function back, and check that print, parse, print gives the same text. In the guest: define functions in both shells and compare `/env/fn#…` and `whatis` byte for byte.
3. **The compiler** to the instruction union, with `-x` tracing.
4. **The interpreter, builtins, variables, globbing and here documents.**
5. **The system interface**, `plan9.c` and `havefork.c` on libc: fork and exec, `Waitfor` and `$apid`, notes and interrupted reads, `/env`, `/fd`, `Isatty`, `rfork`.
6. **Comparison with stock in `usbzig.rc`**: small scripts run by both shells, comparing output, errors and `$status`, covering quoting, `^` and free carets, lists, `$#`, `$"`, subscripts, globbing, `switch` and `~`, `if not`, `while`, `for`, functions (exported from a stock rc to a Zig rc and back), local assignments, every redirection, here documents quoted and not, `|[2]`, `` `{} `` with `$ifs`, `<{}` and `>{}`, `&`, `$apid` and `wait`, `!`, `@{}`, `eval`, `.`, `exec`, `exit`, `shift`, `flag`, `rfork`, `whatis`, syntax errors with line numbers, `-c`, `-e`, `-x`, `-i`, `-n`, and an interrupt sent as a note.
7. **Integration**: `usbzig.rc` itself run by the Zig rc; the Zig rc bound over `/bin/rc` to build programs with `mk`, whose recipes are rc, comparing the results; then planZ booted with the Zig rc as `/bin/rc` for `bootrc`, `rcmain`, `termrc` and `riostart` (`test-boot`, `test-usb`; a `-Dzigrc` option).

Estimate: about 5,000 lines of Zig with tests, about four times grep and sed together. Booting to rio on a Zig shell is the milestone.

Progress:
- **Sources.** 9front 11952's rc (from the ISO, unpacked in the gitignored `ref/src/`) is the same as the 9front checkout file for file, `yaccpar` too, so the port follows the release the tests compare against.
- **The tables.** `tools/yacctab.sh` boots stock 9front, runs its `yacc -d /sys/src/cmd/rc/syn.y`, prints `y.tab.c` and `y.tab.h` on the serial console with their SHA-1s, cuts them out and checks them, and `tools/yacc2zig.py` copies the tables and token numbers into `src/user/cmd/rc/syn_tab.zig` (the header records both SHA-1s). The stack is rc's `YYMAXDEPTH` of 500, not yacc's 150.
- **Steps 1 and 2** (`src/user/cmd/rc/`): `io.zig` (with `pfmt`'s verbs checked against their arguments at compile time), `lex.zig`, `tree.zig`, `var.zig` (keywords and variables), `here.zig` (reading here documents), `pcmd.zig`, `syn.zig` (yaccpar's driver as a labeled switch, and syn.y's actions), with the parts of `exec.zig`, `plan9.zig`, `trap.zig` and `getflags.zig` they use.
- **Host tests** (`zig build test`, with `hostlibc.zig` as libc): tokens (free carets, `SUB`, redirections, `$#`, `$"`), parsing and printing of the constructs, syntax errors and their messages, and all 126 rc scripts of 9front's `rc/bin` (1,778 commands) parse and what they print parses again. Printing need not be a fixed point, in stock rc either: whether two commands print on one line with `; ` depends on their line numbers, which printing a block over several lines changes.
- **Against stock, once** (a guest run, not yet in `usbzig.rc`): each test case and each rc script of `/rc/bin` wrapped as `fn x {…}`, sourced, and printed by `whatis x` in stock rc, against the same through the port's parser and printer: all 170 the same (6,030 lines), and the one case stock rejects (``echo `` a``) the port rejects too. Step 6 makes this a standing check, stock rc against the Zig rc.
- **Kept from C:** the first digit of a redirection's fd goes into the token twice, so messages show `token '>[22=': redirection syntax` for `>[2=`; `if(c)cmd`, `for(i)cmd` and `while (c){` print without the spaces one might expect; a simple command's redirections print before it (` <a  >b cat`).
- **Fixed from C:** the fd digits of a redirection are copied into the 8,192-byte token with no bound in the C; the Zig stops with the C's "token buffer too short".
- **Step 3, the compiler** (`code.zig`, with `deglob` in `glob.zig` and the builtins' names in `simple.zig`). An instruction is a tagged union holding its operands (`pipe: struct { fd0, fd1, right, end }`, `fn: struct { end, str }`, `word: []u8` …); a pc counts instructions, and `Code.wordpc` gives the C's word pc for the `-r` trace, so traces can be compared with stock's in step 6. The `rfork s` that `&` inserts is `.builtin = .rfork`, an enum, not a function pointer. Host tests: listings derived from `code.c` by hand for simple commands, assignments with and without a command, `if`, pipes, `for`, `switch`, `&` and backquotes, all as the port compiles them; the `if not` and `case missing in switch` errors; all 126 9front scripts compile without errors; and `wordpc` against the C's layout.
- **Steps 4 and 5 together**, since the interpreter's instructions fork, open and wait through the system interface: `exec.zig` (threads, the argument stack, redirections, every instruction, `Xrdcmds`, and `main` with its bootstrap code), `simple.zig` (`Xsimple`, `exec`, the path search and all the builtins, `rfork` and `finit` among them), `glob.zig` (matching, the directory walk and `globword`), `here.zig`'s `psubst`, `trap.zig`, `getflags.zig`, `havefork.zig` and `plan9.zig` (`/env`, `Waitfor`, notes through libc's `atnotify`, exec with slices, fork). `zig build user` makes `rc` (224K); 6,040 lines in all, with the tests.
- **Host tests** run rc code as rc runs a file (`execcmds` and `Xrdcmds` on an interactive base thread), with `hostlibc.zig` refusing anything that needs the system and collecting fd 2: lists, subscripts, `^`, `$#`, `$"`, functions and their arguments, `switch`, `~` (UTF-8 ranges too), `if not`, `for`, `while` with `shift`, local assignment and `eval`, 21 values in all, and the errors of `^` and `=`.
- **In the guest, first look** (a scratch script, not yet in `usbzig.rc`): eight scripts run by the Zig rc and by stock rc, output, errors and exit status (`name pid:` masked), all the same: variables and lists, functions and `whatis`, `for`, `if not`, `switch`, `while` with backquotes and `hoc`, every redirection, here documents to a command and to a file, pipes, `<{}`, `cd`, globbing, `@{}`, `&` and `wait`, failing commands and pipeline statuses, functions and variables exported to a child (stock) rc, `eval`, `shift`, `flag`, `$ifs`, ``` `` ```, errors, and `exit` with a status.
- **Fixed from C:** `flag`'s table has 256 entries where the C's has 128 and is indexed with any byte.
- **Kept from C:** a lexer error returns EOF to the parser, so `echo >[x] y` prints `redirection syntax` and then `syntax error` on the next line. Stock does the same (step 6).
- **Kept from C:** rc is built with 6c, whose `char` is signed: a 0xff byte ends a here document's line and its reading (it equals `EOF`), and `pwrd` never quotes bytes from 0x80 up, so `whatis` prints a 0xff byte and UTF-8 bare. Stock does the same (step 6).
- **Step 6, the comparison in `usbzig.rc`.** `tools/rccases` (installed beside the programs) holds 29 scripts; `usbzig.rc` runs each with planZ's rc and with stock rc, in an empty directory and an environment with only `true` and `false` (9front has no such programs, so they are functions) and `$RC`, the rc under test, for the scripts' own child shells. Output, errors and the final status are compared after masking pids, addresses and planZ's path. They cover quoting and carets, lists and subscripts, `~` with UTF-8 classes, every control structure, functions and `sigexit`, local assignments, every redirection (closing included), here documents (quoted, in functions, to files and pipes), pipes and their statuses, `|[2]`, backquotes with `$ifs` and a split word, `<{}` and `>{}`, globbing, `&` with `$apid` and `wait`, `@{}`, every builtin with its errors, `exec`, `rfork`, export of variables and functions between stock and planZ's rc in both directions, statuses, 17 syntax errors with line numbers, the flags `-c -e -x -s -v -V -p -I -m` and bad ones, `-i` with prompts and `. -i`, `-r` traces (about 1,000 lines with rcmain's), interrupt, hangup and term notes with and without traps, the signed-`char` cases above, `whatis` of odd values and functions, and every script of `/rc/bin` and `rcmain` as a function printed back by `whatis` (116,865 bytes). All the same as stock.
- **Kept from C:** pfnc.c's name table has no `Xsettrue`, `Xsub` or builtins, so `-r` prints an address for them; the port prints the instruction's address there.
- The `notes` case sends a note half a second after starting a child rc; a guest slow enough to miss that would differ from run to run.
- **Step 7, integration.**
  - `test-zuser` runs `usbzig.rc` twice in one boot: under stock rc, then under planZ's rc (`/tmp/zig/rc`, left there by the first run). Both runs: all the same as stock, libctest ok. Its timeout and `test-usb`'s are now 900 seconds: `zig/run` now takes several minutes (fltest alone is about 2½ under TCG).
  - **mk** (`mks` in `usbzig.rc`): 9front's `rc`, `grep`, `hoc`, `awk` and `mk` built by stock `mk` with planZ's rc bound over `/bin/rc`, and again with stock rc, each in the same directory (6c records the source's path): mk's output, its status and the SHA-1 of every file made are the same. A directory's sum is left out, since it holds its entries' times (`awk/test` differed for that alone).
  - **`-Dzigrc`** boots 9front's user programs with planZ's rc as `/bin/rc`. The loader also takes `boot/rc` and `boot/rcinit` from the boot volume (DIFF: the names past 9front's bootdir list), and plan9.ini gets `init=/boot/rcinit`. 9front's boot program binds `/boot` into `/bin` ahead of the boot file system, so `bootrc` already runs under `/boot/rc`; `bootrc` ends with `exec $init`, and `tools/rcinit` runs `init -t` with a command that binds `/boot/rc` over `/bin/rc` in the name space `init` builds from `/lib/namespace`, then runs `termrc` and the profile with it, and so `riostart`, rio and every window. A terminal only. In the window, `/bin/rc` and `/amd64/bin/rc` are planZ's (228,676 bytes). The USB image takes the same with `-Dzigrc`.
  - With `-Dzigrc`: `test-9front`, `test-disk`, `test-net`, `test-rio`, `test-audio` and `test-zuser` pass; `test-usb` passed once in three runs, the other two failing on the floating point fault below. Under `-Dzigrc` the "stock" rc of the rc cases is planZ's too, so those compare it with itself; the other programs' cases all run under it.
  - `libctest` checks that an exec'd program starts with 9front's initial floating point state (mxcsr 0x1900, fcw 0x232) whatever the old program left in the registers. It passes.
- **Open: floating point registers go wrong in user processes, now and then (kernel).** Seen while testing step 7, and not from rc. Under load, a process computing with doubles sometimes gets wrong values partway through: planZ's `primes` printed `nn + j` with `nn` gone to 0 (its sieve was right), planZ's `fltest` stopped with "integer part of floating point value out of bounds" (once) or ran on for 19 minutes (once), and 9front's own `primes`, under stock rc in a normal boot, gave a wrong list once in 240 runs and died once with `sys: trap: fault read addr=0xfffffffff0401b2b`, an index made from a bad double. So it is the kernel's, most likely the saving and restoring of floating point state across context switches (`arch/amd64/fpu.zig`); 9front on the same machine has not been tried. Four loops of `primes 9007199254740000 9007199254740992` side by side reproduce it in a few minutes. A suspect read and not confirmed: `fpuprocsetup` (exec) marks the state FPinit without setting TS, as 9front's does, so a process whose exec never sleeps (a program from the kernel's own `/boot`, as `-Dzigrc` makes `/bin/rc`) would leave TS clear for the next process on that processor; an exec from a mounted file server always sleeps in its walk and so gets TS set by the context switch.

### Later
- aarch64 port (QEMU `virt` first: GIC, PL011, virtio-mmio or PCI).
- Userland in Zig: libc, `boot`, `rc`, core utilities, file servers, then the long tail. The first step, a minimal libc, is planned above under M9; the rest is still to be examined as a topic of its own. `src/user` already shows that Zig can produce Plan 9 a.out binaries without a host tool.
- File servers are user programs, so `gefs`, `cwfs` and `hjfs` run unmodified as stock binaries from M7 and need no port for the kernel to use them. When userland is ported, `gefs` (about 12K lines of C) is the file server to do first.

## Future additions

- **Real-time scheduler.** 9front's EDF scheduler (`port/edf.c`, 638 lines, plus hooks in `proc.c` and the `/proc/n/ctl` real-time commands) is deliberately left out. When porting `proc.c`, mark each removed EDF hook with `// DIFF: edf` so the insertion points are easy to find later.
- **GPU driver on the "No Graphics API" model.** The user wants the eventual accelerated graphics driver to expose the interface of Sebastian Aaltonen's article (https://www.sebastianaaltonen.com/blog/no-graphics-api) rather than a classic one: CPU-mapped GPU memory handed out like malloc, 64-bit GPU pointers that shaders follow, one global bindless texture heap indexed by number, one root pointer per draw or dispatch, coarse barriers with no per-resource lists, one-shot command buffers. The user's Zig port of the reference library is `../zig-nographicsapi` (Zig 0.17; today it sits on Vulkan 1.4 and Metal 4), and `../NoGraphicsAPI` is the C++ original. Not planned yet. What it means for the kernel: a native driver for the card (the test machine has an AMD RDNA2 card, the article's minimum generation for AMD), GPU virtual memory and mapping its memory into processes, command submission and fences, shader compilation in user space, and a file interface for all of it. Linux's `amdgpu` is mostly MIT-licensed and is the reference for the hardware, but it is very large. Until then the screen is the UEFI framebuffer drawn by `devdraw`.
- Mount cache (`cache.c`).
- Swap, if ever wanted.
- Optional devices: vmx, dtracy, aoe, bridge, shr, fs, kprof, segment.

## Risks

| Risk | Mitigation |
|---|---|
| Zig 0.17 build API, UEFI target and asm details differ from memory | M0 exists to flush these out; read the std sources rather than guess |
| Error-union rewrite changes behaviour where C relied on longjmp (notes interrupting `sleep`, `error()` deep in drivers) | Convert each site by hand against the original |
| ABI drift (Ureg, Tos, notes, `/proc` text) breaks stock binaries | Comptime layout asserts; compare against stock 9front running in a reference VM |
| MSI-only excludes a device someone needs | Interrupt interface allows a static INTx table; add per platform |
| Some 2011–2012 machines are BIOS-only | Out of scope unless hit; a multiboot front end can fill the same `BootInfo` |
| x86-only assumptions creep into `port/` | `check-ports` build from M2 |

## Working method

- Read the whole original file before porting it; keep function order in the ported core.
- After each file: build, `zig build test`, `zig build test-boot`.
- Commit per file or small group, naming the originals.
- Keep the status table current.

## Status

| Milestone | State |
|---|---|
| M9 | in progress: booted on the machine 2026-11-12 (see "First boot on the machine"): rio from a USB stick, keyboard and mouse through a high-speed hub, the on-board RTL8125B on DHCP with `ip/ping` answered. `usb-image` builds the stick (`test-usb`); `#$` gives `pci -v`. Open: sound, the Zig programs and the USB Ethernet adapter on the machine, `ether8125`'s `rcr` bit 17 |
| M8 | done: stock `rio` runs on the UEFI framebuffer with keyboard and mouse, through the PS/2 controller or through xHCI with no PS/2 at all; `test-rio` checks a screenshot, a typed command and a moved mouse; all test steps pass on the three CPU models, the three disk buses, with 1, 4 and 8 processors, and in a debug build. All of it on QEMU only |
| M7 | done: stock 9front boots from its disk image (hjfs root) on virtio-blk, NVMe and AHCI; `ip/ipconfig` gets a DHCP lease; `hget` works over HTTP and over TLS; `test-boot`, `test-9front`, `test-disk` and `test-net` pass on all three CPU models, with 1, 4 and 8 processors, and in a debug build. All of it on QEMU only |
| M6 | done: all processors start and schedule; `test-boot` and `test-9front` pass with 1, 4 and 8 processors on all three CPU models; the one-hour parallel run on four processors passed (98M processes created, 164M pipe round trips, 472M lock acquisitions, no panic) |
| M5 | done: stock 9front `boot`, `paqfs` and `bootrc` run on the kernel and reach an interactive `rc` on the serial console; `/dev`, `/proc`, `/env`, `/srv` and union directories work from the shell. Tested by a scripted console session on all three CPU models and in a debug build |
| M4 | done: the first process runs `initcode` in user mode and execs `/boot/boot`; fork, exec, exits/await, pipes, brk, rendezvous, notes, alarms and FPU state work; an unmodified 9front `/amd64/bin/echo` runs. Tested on all three CPU models and in a debug build |
| M3 | done: `chan`, `dev`, `pgrp`, `qio`, `allocb`, `parse`, 9P marshalling (`lib/fcall.zig`), and devices root, cons, env, pipe, srv, dup. The boot self-test binds `#c #d #e #s`, writes `/dev/cons`, checks error text, uses `/env`, round-trips a pipe and copies a name space |
| M2 | done: kernel processes sleep, wake, queue on locks, get preempted, take notes and alarms, exit and are reused; the scheduling self-test ran for 60s. Not done: rendezvous, which is a system call and moves to M4 |
| M1 | done: `zig build test` (host) and `zig build test-boot` (two boots: clean self-test, deliberate fault) pass on `SandyBridge`, `Opteron_G4` and `max`, in safe and debug builds |
| M0 | done: `zig build test-boot` passes on QEMU q35 with `-Dcpu=SandyBridge` (default), `Opteron_G4` and `max` |

Notes from M9 so far:

- **USB stick.** `zig build usb-image -Dref=ref -Ddisk=…` writes `zig-out/planz-usb.img` with `tools/mkusb.py` (python3 and `qemu-img` only; it writes the MBR and the FAT volume itself): partition 1 is the boot volume, partition 2 a copy of the 9front image's Plan 9 partition. `tools/usb.ini` is its `plan9.ini`: no `console=`, `user=glenda`, and `nobootprompt=local!usbroot` with an rc function that waits for `/dev/sdU*/fs`, because the device name is a hash that cannot be known in advance. `test-usb` (`tools/usbtest.sh`) boots that image from `usb-storage` with no PS/2 and no other disk.
- **KVM finds what TCG hides.** `-enable-kvm -cpu host` on the development machine (an AMD Zen 3) showed a self-test panic that never appeared under TCG: the first process ran on the other processors while the first one was still starting more with interrupts off. They now wait for `mpinit` to finish. Run new platform code under KVM as well.
- **Boot order**: memory, allocator and screen come before the CPU baseline check, ACPI and the timers, so that every panic is visible. Four white blocks at the top left mark the stages before the console exists. An `init:` line names each stage as it starts. A panic repeats its message after the stack, stops the other processors and never resets.
- **`plan9.ini` variables added**: `*gopmode=WxH`, `*bootpause=seconds`, `*memmap=`, `*xsummary=`, `*nopcilist=`, `*nohpet=`, `*selftest=off`; later `*poolflags=N` (debugging flags for the main and image pools: 1 antagonism, 2 paranoia) and `*imagemaxmb=N` (the image pool's limit, as in 9front).
- **No HPET is not fatal**: the ACPI PM timer calibrates instead. **A serial port exists only if a UART answers a probe**; the wait for its transmitter is bounded.
- **The loader** decodes `PixelBitMask` modes, tries every GOP handle, can set a mode, and maps the framebuffer into the direct map so the kernel can draw before its allocator works (`dmap_span` in BootInfo).
- **Drivers**: xHCI, NVMe and AHCI poll when their interrupt does not arrive and say so; NVMe honours MDTS and asks for its queue count; AHCI refuses controllers without 64-bit DMA. Read but never run, because QEMU cannot produce them: xHCI 64-byte contexts, scratchpad buffers and the firmware hand-off, low-speed devices, transaction translators, a second IOAPIC, DMA above 4GiB.
- **`devpnp`** (`#$`, `port/devpnp.zig`): the PCI files only; ISA PnP is left out. Stock `pci -v` works.
- **`ether8125`** (`port/ether8125.zig`, card type `rtl8125`): the board's Realtek RTL8125B. Not from 9front, which has no driver for it: the structure is `ether8169.c`'s, the registers and the bring-up sequence are OpenBSD `rge`'s (ISC). **Never run on the chip**; QEMU has no model. Its bring-up register sequence was compared, access by access, with `rge_init` run against a simulated chip. No PHY or MAC microcode is loaded, no checksum offload, TSO, VLAN or jumbo frames. `*rtl8125nophy=1` skips the PHY parameter writes. It polls if no interrupt arrives, and `cat /net/ether0/ifstat` dumps registers, rings and counters for debugging from a text file. Linux and Realtek sources (GPL) were not used; planZ stays MIT.
- **USB Ethernet works with no kernel change**: stock `nusb/ether` on a CDC adapter (QEMU `usb-net`) gets a lease and passes the 3MB HTTP and HTTPS downloads, on a root port, behind a hub, and from the USB stick with storage on the same controller. `test-usbnet` (`tools/usbnettest.sh`). A real adapter has not run; the RTL8153 the user has is built into a USB 3 hub, and USB 3 hubs have never run (QEMU has none).
- **`vmap` above 1024GiB.** Device memory below `VMAPSIZE` is mapped at `VMAP` plus its address, as in 9front. Above it, 9front borrows unused physical address space with `upaalloc`; planZ instead hands out slots of a 256GiB region `VMAPHI` between `VMAP` and `KZERO` (`arch/amd64/mmu.zig`), keeps a table of them so `paddr` answers correctly, and never reuses a slot after `vunmap`. Seen working under `-enable-kvm -cpu host`, where OVMF puts device BARs near 56TiB: virtio-net and xHCI map and rio runs with USB input. The real board's BARs, seen from Linux, are below 512GiB.
- **QEMU's default 8-port `usb-hub` is refused by stock `nusb/usbd`**, and QEMU adds one by itself when a controller runs out of root ports: use `-device qemu-xhci,p2=8` or `usb-hub,ports=4`.
- **`bootchat.sh`: an empty `send` followed by a text printed at once can miss that text** (seen under KVM with `usbtest.sh`'s `usbroot:` step).
- **The kernel's share of memory stops at 4GiB.** As in 9front the split is made once at boot (40% for a terminal, 30% for a cpu server) and nothing moves afterwards. 9front limits the kernel's share to the 2GiB of its address region; with the direct map that limit had gone, and a 32GB machine would have kept 13GB for the kernel. `*kernelpercent=N` in `plan9.ini` still asks for an exact share and is not capped. Making the split dynamic (the kernel borrowing from and returning to the page pool) belongs with the allocator rework.
- **The allocator is 9front's.** `port/pool.zig` is libc's `pool.c` with its layout unchanged, and `port/alloc.zig` is `9/port/alloc.c` on three pools (main, image, secrets) whose arenas come from `xalloc`. Free neighbours merge, a 4MB window takes 4MB, and deleting windows gives image memory back (draw curalloc returns to the byte; a burst of 30 large windows peaked at 78MB of image arenas against 142MB before). Arenas are never returned to `xalloc`, as in C. malloc returns memory aligned to 16 without any change to the pool: the two 4-byte tag words (caller pcs) after the 8-byte block header put the caller's pointer 16 bytes into a block, and `xalloc` now hands out multiples of 16, so blocks start on them. That holds only while a pool does not compact; `imagmem.move` is left nil where 9front's `memimageinit` sets it, so a full image pool fails an allocation instead of moving pixels. `mallocalign` honours offset and span; `smalloc` and `secalloc` wait in `resrcwait`. `tools/poolref` builds the C for the host and `pooltest.zig` (in `zig build test`; Linux x86_64 only, it needs a fixed mapping) replays the same random operations on both: every placement is identical over 2,800 runs. Seven bugs of the C are fixed and one is left (pool.zig's and alloc.zig's headers; the list is at the top of `tools/poolref/main.c`); none is reachable from the kernel's current callers. The system boots to rio with `*poolflags=1` and `=3`, and every test step passes with antagonism compiled into all three pools. Process creation in the self-test is about 10% slower under KVM with 12 processors than with the old size-class allocator; the cause was not isolated. A free into the wrong pool is not detected. `allocb.zig` still has a plain `tsleep` with a comment waiting for `resrcwait`, which now exists.
- **Comparing kernels: `tools/kbench.sh`.** It boots stock 9front's `9pc64` (with 9front's own UEFI loader from the ISO) and planZ at any git revisions in identical QEMU/KVM machines and runs `tools/kbench/bench.c`, compiled once in the guest with 6c, on a plain console with rio kept off (`norio=1`, via a profile edit on a scratch overlay of the disk image). Measured 2026-11-11 under KVM on the Ryzen 7 5700X development machine, ns per operation, medians of 5 runs (1 processor) and 3 runs (4 processors), planZ ReleaseSafe: on 1 processor, null system call 106 (9front) / 97 (planZ), pipe round trip 2299 / 1941, fork and exit 10147 / 10016, fork with 16MB to share 50599 / 35267, fork and exec 84792 / 71596; on 4 processors planZ's lead grows (fork and exec 90058 / 72830; four forking processes at once 59206 / 41557). The pool allocator port cost about 4–6% on fork, pipe and exec against the old size-class allocator (`d42e8d4`). The host's clock agrees with both kernels' to within 3%. Not a verdict on design: 9front is built by its own compilers, planZ by LLVM, and planZ leaves out some of 9front (EDF, swap, the mount cache). Four processes forking at once took about four times as long per fork, counted over all four, as one process alone; for each process that is 16 times as long. The cause is idle processors waiting too long, not lock contention; see the next note.
- **kbench again, 2026-11-12** (after the scheduler fix, the slice system calls and the `%s` change; same machine, ns per operation, medians). 1 processor, 5 runs: null system call 106 (9front) / 97 (planZ), pipe 2316 / 1978, fork and exit 10253 / 10183, fork with 16MB 50692 / 35692, fork and exec 85569 / 71591. 4 processors, 3 runs: fork and exec 93680 / 72852, four forking processes at once 61110 / 41421. planZ's times moved by 0–2%, about as much as 9front's did between runs, so the changes cost nothing measurable. Four processes forking at once take 4.3 times as long per fork as one alone on planZ, 5.8 times on 9front. The preparation boot now clicks rio's console window first (`riofocus.sh`), as the tests do: one run lost the focus race and typed into another window.
- **Idle processors and MWAIT.** `runproc` takes a process that last ran on this processor at once, but it halts once in `idlehands` before it takes one that last ran on another. Nothing wakes a halted processor when a process becomes ready, so it sleeps until its next interrupt, up to a 10ms tick. 9front's `idlehands` therefore waits with MONITOR/MWAIT on `nrdy` when the processor has them and there is more than one; planZ only halted until `l.zig`'s `idlehands` was ported. KVM hides MWAIT from guests unless QEMU has `-overcommit cpu-pm=on`, so under plain KVM both kernels halt. Four forking processes on 4 processors (kbench `fork4x`, ns per fork, medians of 2 runs): plain KVM 59674 (9front) / 41399 (planZ before and after the port); with `cpu-pm=on` 22456 / 17063; planZ with an idle loop that spins instead of halting (an experiment, not kept) 17151. One process alone takes about 9500, so four together still get less done than one does, where four times as much would be ideal. A contention profile (temporary counters, not committed) of four processes making 200,000 processes between them, under KVM with MWAIT, found two shared locks:
  - **The text segment's qlock in `fault`.** Every child starts with empty page tables and faults its pages in one by one. Every page fault takes the segment's qlock, and all the children share one text segment, so they queue behind each other: about 10 sleeps per fork, 13.5G cycles of waiting in all.
  - **The pool lock.** `malloc` and `free` are one `ilock` for the whole machine; fork and exit allocate often. 1.2M contended acquisitions, 3.1G cycles spinning, and the clock samples land mostly in `ilock`/`iunlock`.

  9front has both by design. Possible remedies, none started: let a child start with its parent's text pages already in its page tables, or take the segment lock shared when a fault only maps a page already in the segment; a per-processor cache of small blocks in front of the pool. With `cpu-pm=on`, fork and exec got 5–15% slower on both kernels. Real processors, including the test machine's Ryzen 5 3600, have MWAIT.
- **rio's focus race, and the tests.** With `console=` set, 9front's `riostart` opens three windows (stats, a shell, and `console`, whose output is copied to the serial port), each from a background job; rio makes the last one created current, and serial input goes to the current window. Which job finishes last is a race: stock 9front under KVM leaves `stats` current every time (so nothing typed on serial reaches a shell), planZ usually leaves `console` current. It is not a kernel difference in behaviour, only in timing; both kernels show the same windows and processes. Keys cannot change rio's current window, so `tools/riofocus.sh` waits for rio's screen and clicks inside the console window through QEMU's monitor and a USB tablet; `test-disk` (now `tools/disktest.sh`), `test-net`, `test-rio` and `test-usbnet` do this after `term%`. `test-usb` already clicked and typed through the emulated keyboard. QEMU's monitor socket path must be under 108 bytes.
- **Unexplained**: one AHCI run with `*nomsi=1` stalled at the first `term%`; five repeats passed.

Notes from M8 for later milestones:

- **Draw libraries** live beside `port/`, one file per C file: `src/kernel/libdraw/` (the part the kernel links), `libmemdraw/`, `libmemlayer/`. `libdraw/draw.zig`, `libmemdraw/memdraw.zig` and `libmemlayer/memlayer.zig` are the headers; functions are imported from the file named after their C file. `libmemdraw/kernel.zig` (not from C) supplies malloc and `werrstr`, from the kernel or from a leak-checking test allocator, which is what lets the libraries be tested on the host. Not ported: `read.c`, `cread.c`, `write.c`, `openmemsubfont.c` (file descriptors; the kernel does not link them).
- **Their tests run in `zig build test`** (`src/kernel/drawtest.zig`). The compositor is compared with the draw(2) definition on random draws; shapes, strings, layers and warps are compared with hashes printed by 9front's own C libraries built for the host. `tools/drawref/` holds that C harness (needs gcc and a 9front tree) and `want.py`, which rewrites the expected text in the test files.
- **Bugs in 9front's libmemdraw fixed here**, each marked `DIFF`: `alphacalc2810`/`alphacalc3679` read the destination alpha from past a one-word constant (wrong results for six operators from a 32-bit source onto XRGB32); `pixelbits` on a replicated image of depth 1, 2 or 4 at some negative x; `bellipse` leaks an image. Left as in C: `memoptdraw`'s 1-bit path ignores the operator.
- **`Memdrawparam.src` and `.mask` are optional**: `loadmemimage` and `cloadmemimage` call `hwdraw` with only `dst` and `r`, as in C.
- **Nothing a program writes to `/dev/draw` may panic the kernel**, which in a safe build means no integer overflow either: the draw libraries wrap where C wraps. `libmemdraw/fuzz.zig` plays a draw client with extreme coordinates, rectangles, clips and formats against the libraries (400,000 calls in `zig build test`; its header lists environment variables for longer runs and page-guarded memory). It found twelve bugs that 9front's C has too, each fixed and marked `DIFF`: among them `memimagedraw` crashing on an inverted clip rectangle, `memaffinewarp` writing outside the image, `memltofrontn` faulting on a window named twice, and ellipses and polygons that loop for a minute.
- **Kernel stack depth in `libmemlayer`.** `_layerop` no longer recurses once per window in front of the piece being drawn: the pieces wait on an explicit stack, pushed so that the callback sees the same pieces in the same order as the C's recursion (host tests compare the two call for call). A screen made on a window still adds a round of `memdraw` → `_memlayerop` → `ldrawop` per level, as in C, and every libdraw client's `screen` is a window on a private screen on its window, so an ordinary rio client is 2 deep and a client of rio inside rio 4. Measured by painting the kernel stack around draw writes: 5.3K at depth 2 and 1.2K more per partly hidden level; at 8K stacks depth 4 came within 450 bytes and depth 5 overran into the heap. So kernel stacks are 16K (LLVM's frames are much larger than the Plan 9 compilers'), and devdraw's `A` refuses a screen whose windows would be more than 8 deep ("screens nested too deep"): depth 8 measured 12.6K of 16K, about 13.8K if a client also hides libdraw's own level. Not measured: affine warps (`w`), whose frame is the largest, and interrupts landing at the deepest point beyond what the runs happened to catch.
- **Open: expensive requests left as in C**: a thick ellipse or disc line end can allocate a 512MB brush, and an arc three masks the size of its radii.
- **Screen** (`port/screen.zig`): no `devvga`, no mode setting; the mode is the one the UEFI loader left, `XRGB32` or `XBGR32`. The screen image is in RAM (from `xalloc`) and `flushmemscreen` copies to the framebuffer, so nothing reads video memory. No palette, no blanking, software cursor only (`port/swcursor.zig`). The console is drawn with memdraw; its font is doubled on screens of 1440 lines or more. As in C, kernel messages go to `/dev/kprint` instead of the screen while a program has it open. `screenputs` runs under `print.zig`'s console lock with interrupts off: nothing it calls may print.
- **`devdraw`** (`#i`), **`devmouse`** (`#m`), **`devkbd`** (`#b`, `arch/amd64/devkbd.zig`, the i8042) and the PS/2 mouse (`arch/amd64/mouse.zig`; serial mice dropped). A machine without an i8042 prints `i8042: no controller` and goes on. `mouseport=ps2` in `plan9.ini` turns the PS/2 mouse on, as in 9front.
- **USB** (`port/usb.zig`, `devusb.zig`, `usbxhci.zig`, `usbxhcipci.zig`): xHCI only; no UHCI, OHCI or EHCI. Stock `nusb/usbd`, `nusb/kb`, `nusb/disk` and `nusb/audio` run on it. Fixed from C: for a hub, `initep` sent Configure Endpoint with the ep0 flag set, which xHCI forbids and QEMU refuses. Not run: controller recovery, 64-byte contexts, scratchpad buffers, the firmware hand-off, low-speed devices, transaction translators, USB 3 hubs, iso input. On QEMU an unplugged device's reader stays blocked.
- **`devshr`** (`#σ`) was ported because every `nusb` program posts itself there.
- **`up()` is one instruction now** (`movq %gs:N`). It used to be `m().proc`, two instructions: a process preempted between them and resumed on another processor read the process running on the processor it had left, and `lock()` counted its lock against that process. Seen once, in a debug build, as `fault: nlocks 1` in a process entering user mode. The GS base of a processor points at its entry of `dat.percpu.machp`; `percpu.up` mirrors `Mach.proc` at a fixed distance from it, and `arch.setup(p)` writes both. A new architecture needs the same property.
- **Tests.** `test-rio` (`tools/riotest.sh`) boots the disk image into rio twice, once with the PS/2 devices and once with `i8042=off` and a USB keyboard and mouse. `tools/qmp.py` takes screenshots and sends keys and mouse events through QEMU's monitor; `bootchat.sh` runs a `send` that starts with `@host ` as a host command. `bootchat.sh` types 24 characters at a time: with rio running, stock `kbdfs` drops typed characters once 128 are waiting. An expected text must not also appear in the echo of the command that produces it. `tools/qrun.sh` takes extra QEMU arguments in `QEMUARGS`.
- **The profile now starts rio** when 9front boots from the disk, and what is typed on the serial line goes to rio's current window.
- *(Superseded in M9: the allocator is now 9front's pool allocator.)* `alloc.zig` rounded every block up to a power of two and never merged free blocks, so a 4MB window's backing store took 8MB.

Notes from M7 for later milestones:

- **Stages.** (1) PCI and disks: done, stock 9front boots from its hjfs root on a virtio disk. (2) Ethernet and the IP stack: done, `ip/ipconfig` gets a DHCP lease, `ip/ping` works, and `hget` through `webfs` fetches a file over TCP with the right checksum. (3) `devtls`, `devcap`, NVMe and AHCI: done, `hget` over TLS works and stock 9front boots from the image on either controller.
- **Tests.** `-Ddiskbus=virtio|nvme|ahci` chooses how QEMU presents the disk image. `test-net` (`tools/nettest.sh`, `tools/nettestd.py`; needs python3 and openssl on the host) downloads a 3MB file over HTTP and over TLS 1.2 with ChaCha20-Poly1305, AES-GCM and AES-CBC/SHA-256 suites from a server on the host's loopback address, comparing SHA-1.
- **`devtls`** (`#a`) uses `std.crypto`. Ciphers: `clear`, `aes_128_cbc`, `aes_256_cbc`, `ccpoly64_aead`, `ccpoly96_aead`, `aes_128_gcm_aead`, `aes_256_gcm_aead`; MACs: `clear`, `sha1`, `sha256`. Not ported: RC4, 3DES, MD5 and the SSL 3.0 MACs. AES key schedules and GCM are composed in the file from std's single-round AES and GHASH: std's own AES contexts are 3-4K each without AES-NI and are passed by value, too much for an 8K kernel stack. Run live as a TLS 1.2 client only; the server role, TLS 1.0/1.1, `ccpoly64_aead` and `aes_256_gcm_aead` have host tests but have not run in the kernel.
- **Host tests inside `port/` files** (pci, netif, devether, ipaux, devcap, devtls) are not run by `zig build test`, because those files import `../arch.zig`, outside a test module rooted at the file. The agents ran them through a scratch root file beside a symlink to `src/kernel`. Giving `build.zig` a test module rooted at `src/kernel` would make them part of `zig build test`.
- **`devcap`** (`#¤`) as in 9front; `auth/as` works.
- **NVMe** (`port/sdnvme.zig`, `sdN`): one submission queue per processor, one completion queue, one interrupt. Not run: more processors than queues, several namespaces, 4K sectors, failure paths, real hardware.
- **AHCI** (`port/sdiahci.zig`, `port/fis.zig`, `sdE`): matches any controller with the AHCI class code, where 9front has a vendor list. Not ported: LEDs and enclosures, the switch of IDE-mode chipsets into AHCI mode. Unlike the C, a transfer the drive reports as failed is an error (the C counts it as done). No NCQ, as in the C. An empty ATAPI drive prints `i/o error 2041` each time it is probed, which bootrc does many times.
- **`alloc.zig` now returns memory aligned to 16**, as `new` and friends always claimed; before, a block could be aligned to 8 only.
- **The self-test no longer checks** that the allocator's total in use returns to where it was, or that at most 50 process slots are in use (now 400): drivers, the network stack and a booting 9front run beside it.
- **IP stack** (`src/kernel/ip/`, one file per C file): IPv4, IPv6, ARP and neighbour discovery, ICMP, ICMPv6, UDP, TCP, ipifc, routing, the Ethernet, loopback, netdev, pkt and null media, `#I`. Not ported: il, rudp, gre, esp, ipmux, igmp. `ipdat.zig` (ip.h and ipv6.h) holds the types, the signature rules, and at its end the list of every cross-file function. `%I %M %V %E` take wrapped arguments: `ipaux.ip(a)`, `mask(m)`, `v4(a)`, `ea(mac)`.
- **Run so far in the IP stack:** DHCP (UDP, broadcast), ARP, ICMP echo, DNS and HTTP over TCP as a client on IPv4, on QEMU's user-mode network only. **Not run:** IPv6 beyond what `ipconfig` does unprompted, listening TCP sockets, fragmentation and reassembly, forwarding and NAT, the loopback medium under load, retransmission (QEMU's network loses nothing).
- `zig build test-net -Dref=ref -Ddisk=...` runs `tools/nettest.sh`: lease, ping, and a 3MB download from a web server it starts on the host's loopback address, compared by SHA-1.
- `conf/pc64.zig` sets `devip.ipprotoinit` (tcp, udp, ipifc, icmp, icmp6) and calls the media link functions.
- `scalednconv` in devip gives a cpu server no more conversations than a terminal until `arch.zig` exports `cpuserver`.
- **Tests.** `-Ddisk=ref/disk/9front-11952.amd64.qcow2` (9front's pre-installed image, in the gitignored `ref/`) attaches the image as a virtio disk in snapshot mode, so it is never changed; with `-Dref=ref` as well, `zig build test-disk` boots from it and uses it. Every QEMU run has a virtio network card on user-mode networking. `CHATLOG=file tools/bootchat.sh ...` keeps the serial log of a conversation.
- **PCI** (`port/pci.zig`, `arch/amd64/pcipc.zig`): configuration space is ECAM from the ACPI MCFG table, I/O ports 0xCF8/0xCFC without one. The firmware's resource assignment is trusted; nothing is assigned here.
- **Device interrupts are MSI or MSI-X only.** `arch.intrenable(irq, f, arg, tbdf, name)` with a PCI tbdf allocates a vector and programs the device's MSI capability, or else every entry of its MSI-X table with the same message (`pcimsixenable`, which 9front does not have). A driver for an MSI-X device must still tell the device which table entry to use (virtio: `Vconf_msixcfg` and `Vconf_queuemsixvect`). A device with neither capability cannot interrupt.
- **Drivers register in `conf/pc64.zig` `links()`**, called before the devices are reset: `devsd.sdifc` lists the disk drivers, Ethernet drivers call `addethercard`.
- **virtio** (`port/virtio10.zig`, `sdvirtio10.zig`, `ethervirtio10.zig`): version 1.0 devices with memory-mapped registers only. virtio-blk and virtio-net run; the virtio-scsi half of the disk driver has not been run.
- **Not ported in the disk and Ethernet layers:** the mmc/sdio interface of `sd.h`, the network console, `isaconfig` as a platform service (devether has a private one for `etherN=`).
- `%T` is `pci.tbdf(v)`, `%E` is `devether.ea(addr)`; NETQID and friends live in `netif.zig` (devpipe and devuart still have private copies).

Notes from M6 for later milestones:

- **Processors** come from the ACPI MADT and are started by `arch/amd64/mp.zig` just before the bootstrap processor enters the scheduler. `conf.nmach` counts them as they come on line; `*ncpu=N` in `plan9.ini` limits them. QEMU runs with `-smp 4` by default (`-Dsmp=N`).
- **AP start-up** uses two pages of low memory: the bootstrap code at 0x7000 (`apbootstrap` in `l.zig`, 16-, 32- and 64-bit code assembled to run at that address) and a start-up page table at 0x8000. If the firmware's memory map does not show both as ordinary RAM the kernel says so and stays on one processor. The first 2MiB stay executable through the direct map for this.
- **Kernel page-table sharing.** Each processor has its own top-level table whose kernel half (entries 256-511) is copied when the processor starts. A top-level kernel entry created after that would exist on one processor only: `mpinit` creates the two for VMAP first, and nothing else may add one.
- **No TLB shootdown interrupts**, as in 9front: a process whose mappings must change gets `newtlb` set and flushes at its next clock tick or switch; `procflushmmu` waits for that.
- **Idle processors halt** and notice new work at their next clock tick (up to 10ms); 9front can use MWAIT instead where the CPU has it. Not ported.
- **No TSC synchronisation** between processors (`syncclock`); the baseline's invariant TSC is assumed to be in step.
- Console output takes a lock (`print.zig`), except while panicking.
- Interrupts from devices all go to the bootstrap processor.
- `conf.copymode` is 1 with more than one processor (copy on reference instead of copy on write), as in 9front.
- The self-test wires a process to each processor and checks that it runs there. Its malloc leak check only runs with one processor, since other processes allocate concurrently.

Notes from M5 for later milestones:

- **Stock boot.** With `-Dref=ref` the build puts 9front's own `boot`, `paqfs`, `factotum` and `bootfs.paq` in the boot volume's `boot/` directory; the loader reads those four names and passes them in `BootInfo.files`, and the kernel serves them in `/boot`. Without a `boot` from the loader, `/boot/boot` is planZ's user-mode self-test. `zig build run9 -Dref=ref` boots to bootrc's "bootargs is" question on the serial console; answer `!rc` for a shell. `zig build test-9front -Dref=ref` does that with `tools/bootchat.sh` and uses the shell.
- **Console.** `plan9.ini` needs `console=0` for bootrc to start `kbdfs` on the serial port (`/dev/eia0`). Kernel prints still go out polled through `print.zig`; `kbdfs` writes through the interrupt-driven queue of the same UART, so the two can interleave.
- **devmnt** has no mount cache; its read-ahead code is ported but uncalled. An Rerror is always `error.Str` with the server's text, so compare text (`proc.errtext`) and not tags when a server's error matters.
- **devproc**: `mem` works through a private port of `segio`; `fpregs`, watchpoints, syscall trace and `/proc/trace` are listed but error-only or empty; the EDF ctl commands are unknown (`// DIFF: edf`).
- **random.zig** seeds for about 3 seconds after boot with a spinning kernel process, as in 9front; `/dev/random` and the first `nrand` block until then. `hwrandbuf` (RDRAND) is not hooked up.
- **`#ec`**: `bootargs.setconfenv()` exports every `plan9.ini` setting; `/dev/config` is still empty.
- **devuart / uart16550**: the driver is generic over its register accessor and asks the platform for its interrupt through a callback; `arch/amd64/uartpc.zig` is the PC glue (COM1, COM2). There is no `intrdisable` yet, so closing a port leaves its handler installed. An explicit `console=0` without a baud rate sets 9600 as 9front does; with no `console=` the port stays at 115200.
- **`/dev/swap`** reports memory statistics with swap as 0/0. Since M9 its "kernel malloc", "kernel draw" and "kernel secret" lines are curalloc/cursize/maxsize of the three pools, as in C.
- `ps` is not in 9front's boot file system, so "ps works" from the plan is checked by reading `/proc/N/status`, which is what `ps` reads.
- **Not exercised yet:** `factotum`, `mntgen` beyond start-up, notes through `/proc/N/note`, `/dev/reboot`, the RTC write path, devsrv posting from user programs beyond what bootrc does, and everything under `/net` (no devices there until M7).
- **Agents' ports still unreviewed line by line:** devmnt, devproc, devuart, uart16550, random, devrtc, devswap, sysfile, sysproc, page/segment/fault. They pass the boot tests; treat anything outside what those tests reach as unproven.

Notes from M4 for later milestones:

- **Allocators.** `alloc.allocator` is the kernel allocator as a `std.mem.Allocator`, for new code that wants standard containers (`std.ArrayList`, hash maps); it fails with `error.OutOfMemory` rather than waiting. Ported code keeps calling `malloc`/`smalloc`/`free`.
- **Reference binaries.** The 9front amd64 ISO (release 11952) is in `ref/iso/`, and its `amd64/` and `cfg/` trees are unpacked in `ref/root/` (`ref/` is gitignored). `ref/boot/` holds `boot` and `bootfs.paq`, cut out of the reference `9pc64` (they exist nowhere else; `bootfs.paq` checks against its own SHA-1). `zig build test-boot -Dref=ref` adds a stock `echo` to `/boot` and requires its output; without `-Dref` the tests need nothing outside the repository. No checksum is published for the ISO.
- **System calls.** A handler is `fn(*Sargs) Error!usize` and takes its arguments with `a.next(T)`. `port/syscall.zig` holds the dispatcher, `donotify` and the table (`systabinit` lists every call). `syscall()` in `arch/amd64/trap.zig` returns non-zero to make the assembly restore all registers (a note or `noted`); the C patches its return address instead.
- **User memory.** `fault.validaddr`, `userslice` and `userstr` are the only way in. `validaddr` now pre-faults every page of the range through `arch.probe`, a fault-safe touch, so a page that cannot be loaded fails the system call with an ordinary error. A validated address that still faults later (another process sharing the memory unmapped it) kills the process if it holds no kernel locks, and panics otherwise. `fault()` itself never unwinds; it returns -1 with the reason in `up.errstr`.
- **No swap, in practice:** `page.zig` keeps a pager process whose only jobs are reclaiming idle cached image pages and, last, killing the largest process.
- **FPU** (`arch/amd64/fpu.zig`): user state only, saved and restored lazily with XSAVE, nested for note handlers. The kernel uses no floating point, so `fpukenter`/`fpukexit` and the kernel save areas are gone.
- **User programs in Zig** live in `src/user`: `user.ld` makes the linker write the a.out header, so `objcopy -O binary` of a link is a Plan 9 executable; `sys.zig` has the system call stubs. `initcode.zig` is the real first process; `boot.zig` is a user-mode self-test standing in for `/boot/boot`. A note handler is entered the Plan 9 way (arguments on the stack), so Zig code needs a small trampoline; see `boot.zig`. This is the seed of a Zig userland, which the user wants examined as its own topic.
- **Not ported in M4:** debug registers and watchpoints, the breakpoint trap, syscall tracing, `segio` (devproc's memory access), `sysfversion`/`sysfauth` (they are in `auth.c`), and the mount half of `mount` (needs devmnt).
- **Still to consolidate:** `evenaddr`, `fullrune`/`utfecpy` and the `NCONT...` constants are private in `sysproc.zig`; `dirchanstat` is private in `sysfile.zig`; `readstr`, `strtoul`, `iseve` duplicates from M3 remain.
- **Bugs fixed relative to the C, on purpose:** `segflush1` rounds its start with `~(BY2PG-1)` (the C clears one bit, which can trip an assert from user space). Noted as upstream-looking and left as in C: the `?:` precedence in `fault()`'s permission check.
- Most of M4 has only been run as far as `boot.zig` and one stock binary go: `segattach`/`segfree`/`segflush`, semaphores, `wstat`, union directory reads, `#!` scripts, and exec failure after the point of no return have not been exercised.

Notes from M3 for later milestones:

- **Device interface** (`port/dev.zig`): entries return Zig errors; `walk` returns an error where the C returns nil; `close` returns `Error!void` and `cclose` ignores it. A device exports its table under its C name (`consdevtab`); `conf/pc64.zig` lists them and `main` sets `dev.devtab`. Entry 0 must be the root device.
- **Ownership on error.** `namec`, `cunique`, `createdir`, device `open` and `create` take a channel and return one; if they fail the caller still owns the one it passed. `walk` leaves `*cp` untouched on failure.
- **Deferred errors.** Where the C leaves text in `up->errstr` to raise later, the Zig returns the error at once or calls `proc.seterror`. `proc.errtext(e)` gives an error's text; `proc.swaperr()` is the C's errstr/syserrstr swap, needed only around `error.Str`.
- `fmt`: `%C` is a rune like `%c`; `%#q` always quotes. `alloc.free` takes any pointer, slice or null; `alloc.new/snew/newslice/snewslice` give typed zeroed memory that the caller must initialise.
- **`/dev/cons` has no input path**, exactly as in 9front: a read fails with Egreg, and user-space `kbdfs` serves the console programs read. A kernel-side shell before `kbdfs` would need a deliberate addition.
- **Union directory reads** are `unionread` in `sysfile.c` (M4); a device `read` on a union's channel lists only its first member.
- `port/lib.zig` holds the libc bits the kernel uses (open/mount flags, runes, `cleanname`).
- **Private stand-ins to consolidate in M4:** `fdtochan` exists twice (`devdup.zig`, `devsrv.zig`) and belongs in `sysfile.zig`; `readstr` is in `devdup.zig` and `devcons.zig`; `strtoul` in `devcons.zig` and `devsrv.zig`; `tokenize` in `parse.zig`; `iseve` in `devenv.zig` and `devcons.zig` (auth.c); `exhausted` and `NETQID` in `devpipe.zig`; `procfdprint` in `devdup.zig` (devproc).
- **Not done in the devices:** `/dev/random`, `/dev/reboot` and `/dev/config` are stubs; the `serialoq` output queue and "kprint replaces the screen" are not connected to `print.zig`; `devsrv`'s permission check during walk has a small race noted in the file.
- **User memory.** `qread`/`qwrite`, `envread`/`envwrite` and `parsecmd` take kernel slices. The C frees buffers when a copy to or from user memory faults; those sites are marked `// M4:`.
- `Dev.bread` cannot return "no block"; `devpipe` returns an empty block at end of file. Revisit when porting devmnt.
- The agents' ports were compile-checked on three architectures and exercised only as far as `port/selftest.zig` goes: `devsrv`, `devdup`, `parse` and most `devcons` files have not been run.

Notes from M2 for later milestones:

- **Context switch.** `setlabel`/`gotolabel` are gone. `arch.swtch(from, to)` saves the callee-saved registers on the stack, stores SP in a `Label`, and returns once, later, in the context that called it. `sched()` is split: the half that runs in a process switches to the scheduler; the half that picks the next process is the loop in `schedinit()` on the processor's own stack.
- **`up` is not a register.** Where the C relies on `up` staying set after `m->proc = nil` (in `schedinit`), the Zig passes that fact as a parameter (`ready0`, `updatecpu`, `reprioritize` take `isup`/`running`). Never hold `arch.m()` across anything that can switch; `m()` is `asm volatile` so the compiler re-reads it.
- **Errors.** `port/error.zig` is generated from `error.h`: each E-string is an error tag, `errstr()` gives its text, `error.Str` means the text is in `up.errstr` (`proc.errorf` sets it). `sleep`, `tsleep`, `eqlock` and `pwait` return error unions; callers that must not be interrupted write `catch {}` and say why.
- **`sleep` returns on any wakeup**, not only when its condition holds, exactly as in C. Callers loop.
- **Stubs left in `proc.zig`**, each marked with the milestone: namespace and file groups in `pexit`/`kproc` and `forceclosefgrp` (M3); segments, `popnote`, the rendezvous case of `procinterrupt`, `procflushmmu`, `palloc` in `sched` (M4). `kproc` panics instead of waiting when the process table is full, until `resrcwait` arrives with `pgrp.c`.
- **edf**: every hook is marked `// DIFF: edf` in `proc.zig`, `taslock.zig` and `portdat.zig`.
- `hzclock` leaves out `flushmmu`, dtracy, kmap invalidation, profiling and shutdown.
- `fpu.zig` only enables XSAVE and leaves CR0.TS set, so any floating-point use in the kernel traps. Process FPU state is M4.
- Kernel stacks are 8K, 32K in Debug builds. `port/selftest.zig` keeps its tables static for that reason.
- `zig build check-ports` compiles `port/`, `plat/acpi.zig` and the UART driver for aarch64 and riscv64 against `arch/stub/stub.zig`. Add each new portable file to `src/kernel/portcheck.zig`.
- `tools/qrun.sh` boots `zig-out/esp` and prints the kernel's serial output; `*schedtest=N` in `plan9.ini` runs the scheduling test for N seconds.
- **QEMU quirk:** QEMU's software CPU hangs on setting CR4.OSXSAVE for any model with XSAVE but without XSAVEOPT. Plain `Opteron_G4` hits it; the AMD test model is `Opteron_G4,+xsaveopt`. This is the emulator, not the kernel: `SandyBridge,-xsaveopt` hangs the same way.

Notes from M1 for later milestones:

- Port code reaches the machine only through `src/kernel/arch.zig`; `arch/amd64/amd64.zig` is the list of what an architecture must provide.
- `lib/fmt.zig` is the Plan 9 verb formatter; a type prints itself for any verb by declaring `fmt9` (use this for `%E`, `%I`, `%V`, `%T` ...). Size modifiers are ignored, `u` is not.
- **Context switch needs a design decision in M2.** The C `setlabel`/`gotolabel` save only SP and PC because the Plan 9 compilers keep nothing in registers across calls. Zig follows the SysV ABI, so RBX, RBP and R12-R15 must be saved too: either widen `Label` or push them on the stack before saving SP. They were left out of `l.zig` for this reason.
- `taslock.zig` has only what M1 needs: `lock` spins without scheduling and there are no priority or statistics hooks.
- *(Superseded in M9.)* `alloc.zig` was a simple size-class allocator; `smalloc` panicked instead of waiting and `mallocalign` did not support `span`.
- `rdmsr`/`wrmsr` have no fault fixup; `trap()` has no `_rdmsrinst`/`_peekinst` cases yet.
- `irq.zig` lacks the interrupt-time histogram, `preempted()` and the `irqalloc` file. `apic.zig` routes ISA interrupts only; MSI comes with PCI.
- An HPET is required to calibrate the TSC; there is no ACPI PM timer or CPUID-leaf fallback.
- The invariant-TSC requirement is waived when CPUID reports a hypervisor, because QEMU hides the flag.
- Machine-check and MTRR set-up from `cpuidentify` are not ported.
- `port/screen.zig` is a text console on the boot framebuffer using 9front's default font (`port/defont.bin`, extracted from `libdraw/defont.c`). It was pulled forward from M8 so boots are visible on machines without a serial port. `vmap` fails for device memory above 1024GiB; a framebuffer placed that high gets no console.
- `*selftest=fault` in `plan9.ini` makes the boot self-test end in a kernel fault; the loader passes `plan9.ini` to the kernel as the command line and `getconf` reads it.

Notes from M0 for later milestones:

- Zig 0.17 renames met so far: `std.lang.Optimize` with `.debug/.safe/.fast/.small`; `@backingInt` instead of `@intFromEnum`; `run.addPassthruArgs()` instead of `b.args`; no install-path query at configure time (QEMU boots from a `addWriteFiles` directory in the cache).
- The kernel file on the boot volume is `planz`; the loader is `EFI/BOOT/BOOTX64.EFI`. `zig build` also installs both under `zig-out/esp`.
- The loader maps physical memory `[0, max(4GiB, top of RAM))` at `DMAP` and at 0. Device memory above that is not mapped; M1's `vmap` must handle it (the QEMU framebuffer is below 4GiB, a real one may not be).
- The loader refuses to boot if the firmware has 5-level paging on.
- `test-boot` is `tools/boottest.sh` (POSIX sh), not a Zig tool.
- `port/print.zig` is a placeholder (`puts`, `hex`, `dec`); replace it with the Plan 9 verb formatter first thing in M1.
- No `zig build test` step yet; add it with the first host-testable module (`lib/fmt`).
