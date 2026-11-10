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
- Default test CPU is QEMU `SandyBridge`; `-Dcpu=Opteron_G4` is the AMD counterpart and `-Dcpu=max` the newest. A milestone is done only when `test-boot` passes on all three.

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
- **Done when:** several kprocs sleep/wakeup/rendezvous under preemption for a minute.

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

The user's test machine: AMD Ryzen 5 5500 (Zen 3), 32GB RAM, Radeon RX 6500 XT. It has no integrated graphics, so the display is the card's UEFI framebuffer. Assume no serial console. Board model, NIC and PS/2 availability are not yet known. Booting it early is cheap: copy `zig-out/esp` onto a FAT32 USB stick.

### Later
- aarch64 port (QEMU `virt` first: GIC, PL011, virtio-mmio or PCI).
- Userland in Zig: libc, `boot`, `rc`, core utilities, file servers, then the long tail.
- File servers are user programs, so `gefs`, `cwfs` and `hjfs` run unmodified as stock binaries from M7 and need no port for the kernel to use them. When userland is ported, `gefs` (about 12K lines of C) is the file server to do first.

## Future additions

- **Real-time scheduler.** 9front's EDF scheduler (`port/edf.c`, 638 lines, plus hooks in `proc.c` and the `/proc/n/ctl` real-time commands) is deliberately left out. When porting `proc.c`, mark each removed EDF hook with `// DIFF: edf` so the insertion points are easy to find later.
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
| M1 | done: `zig build test` (host) and `zig build test-boot` (two boots: clean self-test, deliberate fault) pass on `SandyBridge`, `Opteron_G4` and `max`, in safe and debug builds |
| M0 | done: `zig build test-boot` passes on QEMU q35 with `-Dcpu=SandyBridge` (default), `Opteron_G4` and `max` |

Notes from M1 for later milestones:

- Port code reaches the machine only through `src/kernel/arch.zig`; `arch/amd64/amd64.zig` is the list of what an architecture must provide.
- `lib/fmt.zig` is the Plan 9 verb formatter; a type prints itself for any verb by declaring `fmt9` (use this for `%E`, `%I`, `%V`, `%T` ...). Size modifiers are ignored, `u` is not.
- **Context switch needs a design decision in M2.** The C `setlabel`/`gotolabel` save only SP and PC because the Plan 9 compilers keep nothing in registers across calls. Zig follows the SysV ABI, so RBX, RBP and R12-R15 must be saved too: either widen `Label` or push them on the stack before saving SP. They were left out of `l.zig` for this reason.
- `taslock.zig` has only what M1 needs: `lock` spins without scheduling and there are no priority or statistics hooks.
- `alloc.zig` is the simple size-class allocator; `smalloc` panics instead of waiting, `mallocalign` does not support `span`.
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
