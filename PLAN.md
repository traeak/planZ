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

### Later
- aarch64 port (QEMU `virt` first: GIC, PL011, virtio-mmio or PCI).
- Userland in Zig: libc, `boot`, `rc`, core utilities, file servers, then the long tail. To be examined as a topic of its own before any of it is planned; `src/user` already shows that Zig can produce Plan 9 a.out binaries without a host tool.
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
| M9 | in progress: prepared in QEMU and KVM, not yet tried on the machine. `usb-image` builds a stick that boots to rio from USB alone (`test-usb`); the boot path was audited for what only works in QEMU; `#$` gives `pci -v`. Open: the first real boot, and a driver for the board's network chip, which is not yet identified |
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
- **Comparing kernels: `tools/kbench.sh`.** It boots stock 9front's `9pc64` (with 9front's own UEFI loader from the ISO) and planZ at any git revisions in identical QEMU/KVM machines and runs `tools/kbench/bench.c`, compiled once in the guest with 6c, on a plain console with rio kept off (`norio=1`, via a profile edit on a scratch overlay of the disk image). Measured 2026-11-11 under KVM on the Ryzen 7 5700X development machine, ns per operation, medians of 5 runs (1 processor) and 3 runs (4 processors), planZ ReleaseSafe: on 1 processor, null system call 106 (9front) / 97 (planZ), pipe round trip 2299 / 1941, fork and exit 10147 / 10016, fork with 16MB to share 50599 / 35267, fork and exec 84792 / 71596; on 4 processors planZ's lead grows (fork and exec 90058 / 72830; four forking processes at once 59206 / 41557). The pool allocator port cost about 4–6% on fork, pipe and exec against the old size-class allocator (`d42e8d4`). The host's clock agrees with both kernels' to within 3%. Not a verdict on design: 9front is built by its own compilers, planZ by LLVM, and planZ leaves out some of 9front (EDF, swap, the mount cache). Four processes forking at once take about four times as long per fork as one does, on both kernels.
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
