# planZ

planZ is the [9front](https://9front.org) kernel ported to Zig. It is
made for amd64 machines from 2011 on that boot with UEFI.

The system calls and the a.out binary format are 9front's, so stock
9front programs run on it unchanged: `rc`, `rio`, the file servers and
the network tools. What programs can see, such as the name space, 9P,
processes and device files, is ported file by file from 9front's
`sys/src/9/port`. The machine layer (UEFI loading, ACPI, APIC, PCIe,
MSI) is written new. Some optional parts are left out, among them
swap, EDF real-time scheduling, legacy system calls and the mount
cache.

## Status

- **QEMU and KVM:** stock 9front boots from its own disk image (hjfs,
  on virtio, NVMe or AHCI). It runs on 1 to 8 processors and gets a
  DHCP lease. `hget` works over TLS, and `rio` runs on the UEFI
  framebuffer with a USB or PS/2 keyboard and mouse.
- **Real hardware:** a USB stick image has booted to `rio`, with
  working typing, on one machine (Ryzen 5 3600, B550 board). Checking
  the rest of that machine is in progress; see
  [docs/hardware-checklist.md](docs/hardware-checklist.md).
- **Not yet:** userland programs written in Zig beyond a seed, audio,
  GPU acceleration, aarch64 and riscv64. The portable kernel already
  compiles for the last two.

[PLAN.md](PLAN.md) has the full plan: decisions, milestones M0 to M9,
what was kept and dropped, and notes from each milestone.

## Requirements

- Zig 0.17
- QEMU (`qemu-system-x86_64`, `qemu-img`) and OVMF firmware, by default
  `/usr/share/qemu/edk2-x86_64-code.fd`
- python3, for the test scripts and the USB image builder
- KVM is optional; tests run under TCG

The tests that boot stock 9front need a `ref/` directory, which is not
in the repository. It holds the 9front amd64 release 11952 ISO, its
unpacked `amd64/` tree, `boot` and `bootfs.paq`, and the disk image.
"Reference binaries" in PLAN.md says what goes where.

## Building and running

```sh
zig build                  # kernel and loader into zig-out/esp
zig build run              # boot the kernel in QEMU, serial console on stdio
zig build test             # host unit tests
zig build test-boot        # boot headless and check the serial output
zig build check-ports      # compile the portable kernel for aarch64 and riscv64
```

With the reference files (`D="-Dref=ref -Ddisk=ref/disk/9front-11952.amd64.qcow2"`):

| Step | What it checks |
|---|---|
| `zig build run9 $D` | Boots to a 9front shell, interactively |
| `zig build test-9front $D` | Stock user programs reach a shell and are used |
| `zig build test-disk $D` | Boots from the 9front disk image and uses the file system |
| `zig build test-net $D` | DHCP, HTTP and TLS |
| `zig build test-rio $D` | `rio` with keyboard and mouse, checked by screenshot |
| `zig build test-usb $D` | The USB stick image booted from a USB disk |
| `zig build test-usbnet $D` | The network through a USB Ethernet adapter |

Useful options include `-Dcpu=` (`SandyBridge` by default, also `max`
and `Opteron_G4,+xsaveopt`), `-Dsmp=`, `-Dmem=`,
`-Ddiskbus=virtio|nvme|ahci` and `-Doptimize=debug`.

## Booting a real machine

`zig build usb-image $D` writes `zig-out/planz-usb.img`. Copy it to a
USB stick with `dd`. The stick has a FAT boot partition and a copy of
the 9front root, and it boots to `rio` with no other disk.
[docs/real-hardware.md](docs/real-hardware.md) covers firmware
settings, what the screen should show, and how to collect diagnostics.

## Layout

```
src/boot/          UEFI loader and the boot contract with the kernel
src/kernel/port/   the portable kernel, ported from 9/port
src/kernel/ip/     the IP stack, ported from 9/ip
src/kernel/arch/   amd64, plus a stub architecture for check-ports
src/kernel/plat/   ACPI
src/kernel/lib*/   libmemdraw, libmemlayer and libdraw for devdraw
src/kernel/conf/   the kernel configuration, as comptime tables
src/lib/           9P marshalling and print formatting
src/user/          user programs in Zig: initcode and a test boot program
tools/             QEMU test drivers, the USB image builder, kbench
docs/              guides for real hardware
```

## Conventions

A ported file starts with `// from 9/port/x.c` and keeps the original's
names and function order. A `// DIFF:` comment marks every place where
the Zig deliberately differs. C's `waserror`/`poperror` become Zig error
unions with `defer`/`errdefer`. Before porting a file, read the whole
original.

## Performance

`tools/kbench.sh` boots stock 9front's kernel and planZ in identical
KVM machines and runs the same benchmark binary on both. Results and
caveats are in PLAN.md.

## License

MIT, the same as 9front. Drivers for hardware 9front does not support
are written from BSD-licensed references (OpenBSD `rge` for the
RTL8125), not from GPL sources.
