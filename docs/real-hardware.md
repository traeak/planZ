# Booting on a real machine

For M9: boot planZ on a PC from a USB stick, with no other disk needed, to stock 9front's `rio`.
Written for the test machine (Ryzen 5 3600, B550 mini-ITX, discrete Radeon, no serial port, USB keyboard and mouse).
So far the stick has only been booted in QEMU; see "Not yet tried on hardware" at the end.

## Make the stick

Needs `ref/` (the 9front reference files) and the 9front disk image, as `test-rio` does, plus `python3` and `qemu-img`.

```
zig build usb-image -Dref=ref -Ddisk=ref/disk/9front-11952.amd64.qcow2
```

This writes `zig-out/planz-usb.img` (3,995,074,560 bytes, sparse; the stick must be at least that big, so 4GB or more) and reads it back as a check.

Find the stick's device name. **`dd` overwrites the whole device it is given; the wrong name destroys a disk.**

```
lsblk -o NAME,SIZE,MODEL,TRAN,RM,MOUNTPOINTS
```

The stick is the line with `usb` under TRAN and the size you expect. Unmount anything mounted from it, then copy to the whole device (`/dev/sdX`, not `/dev/sdX1`):

```
sudo dd if=zig-out/planz-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
```

All 3.8GB are written, which takes a few minutes on a USB 2 stick.

### What is on it

| Partition | MBR type | Sectors | Contents |
|---|---|---|---|
| 1 | `0xEF` EFI system | 2048–83967 (40MiB) | FAT32, made by `tools/mkusb.py`: `EFI/BOOT/BOOTX64.EFI` (planZ loader), `planz` (kernel), `plan9.ini` (from `tools/usb.ini`), `boot/boot`, `boot/bootfs.paq`, `boot/paqfs`, `boot/factotum` (stock 9front) |
| 2 | `0x39` Plan 9 | 83968–7801152 (3.7GB) | Byte-for-byte copy of the Plan 9 partition of the 9front image: its `9fat` (unused), `nvram` and `fs` (the hjfs root) |

Partition 1 can be mounted on Linux to change `plan9.ini` or replace `planz` without writing the stick again.
`-Dusbesp=N` changes the size of partition 1 in MiB (below 33 it becomes FAT16, which also boots).

## Firmware settings

Enter setup (usually Del) and check:

- **Secure Boot: off.** The loader is not signed.
- **CSM: off** (pure UEFI boot). With CSM on, the firmware may try to boot the stick the BIOS way, which it cannot, or give no UEFI framebuffer.
- **Fast boot: off**, so that USB devices are set up and the stick is offered.
- **XHCI hand-off: enabled**, if the option exists. The kernel also asks the firmware for the controller itself.
- Leave "legacy USB support" alone at first. If keyboard, mouse or stick do not work in planZ, try it disabled.

Then pick the stick from the boot menu (usually F11 or F7 at power-on); the entry starts with `UEFI:`.
Plug the stick, keyboard and mouse straight into ports on the back of the board, not through a hub, monitor or front-panel cable.

## What you should see

Nothing needs to be typed. In QEMU the whole boot takes about 25 seconds, most of it after the kernel has started.

1. **Loader**, a few lines of firmware text: `planz loader`, `kernel … bytes at …`, `framebuffer WxH …`, `acpi rsdp …, 4 boot files`, `starting the kernel`.
2. **Kernel**, text in a framed "Plan 9 Console": `Plan 9`, memory lines, `init: …` lines naming each stage as it starts, one `cpuN:` line per processor, a `usbxhci:` line per USB controller, `i8042: no controller` if there is no PS/2, and `selftest` lines ending in `selftest ok`.
3. **bootrc**: `usbroot: hjfs on /dev/sdUxxxxx/fs`, then `hjfs: fs is /dev/sdUxxxxx/fs`, then `init: starting /bin/rc`.
4. **rio**: a grey screen with a small `stats` window at the top left and a shell window with a `term%` prompt.

**Click in the shell window before typing.** Either of the two windows can end up as the current one; typing into `stats` does nothing (and `q` closes it).

To shut down, type `fshalt`, wait for "It's now safe to turn off your computer", and power off. hjfs can lose recent changes if the power just goes; write the image again to start clean.

## If it stops

Photograph the whole screen at the point where it stops; the last few lines say where.

| What you see | What it means | What to try |
|---|---|---|
| The stick is not in the boot menu, or something else boots | The firmware did not accept the stick | The settings above; another USB port; write the stick again |
| Stops in the loader's lines | The loader's last line is the error | Photograph it |
| Black screen after `starting the kernel` | The kernel started but has no console on this framebuffer, or died before it had one | Note the `framebuffer` line from the loader |
| Kernel text stops, no `panic` | The last `init:` line names the stage that hung | Photograph; try `*ncpu=1` in `plan9.ini` to rule the other processors out |
| `panic: …` | Kernel bug | Photograph everything from `panic` down |
| After 20 seconds: `usbroot: no USB disk with an fs partition`, a list of disks and `bootargs is (tcp, tls, il, local!device)[…]` | The kernel or `nusb/disk` did not find the stick | If the keyboard works, see below; photograph the list |
| `bootargs is …` and the keyboard does nothing | USB keyboard not working | Another port or keyboard; nothing can be typed, so photograph |
| rio appears but the pointer or keys do nothing | USB HID problem | Try the other device first; a working keyboard alone is enough to collect information if the shell window is current |

### Reading the early stages

- **Loader.** A loader error stays on screen for 15 seconds. No `framebuffer` line means the firmware offered no usable graphics mode; try `*gopmode=1920x1080` in `plan9.ini`.
- **White blocks.** Before it has a console the kernel draws up to four white blocks at the top left, one per stage. Count them if nothing else appears after `starting the kernel`:

  | Blocks | The kernel stopped in |
  |---|---|
  | none | its first instructions |
  | 1 | identifying the processor |
  | 2 | recording the memory map |
  | 3 | setting up its allocator |
  | 4 | setting up the screen |

- **`init:` line.** Stage names collect on one line (`init: mmu apic fpu timers proc uart pci links root cons … mp cpu1 … sched`); the last name is the stage in progress. One ending in `cpuN` means that processor did not start cleanly.
- **Summary lines** worth having in the photograph: `mem:`, `screen:` (should say `write-combining`), `acpi:`, `cpu0: tsc … Hz by HPET` (should be near 3.6GHz), `apic:`, `IOAPIC:`, `pci: ecam`, the PCI list, and one `usbxhci …: v… ports … ctx … scratch …` line per USB controller.
- **A reset or reboot loop** with nothing readable: set `*bootpause=10` to hold the summary on screen, then try `*ncpu=1`.
- **A panic** prints its message again after the stack dump and stops; it never resets the machine.

Messages that point at a cause:

| Message | Meaning |
|---|---|
| `mp: the firmware uses the memory at 0x7000-0x9000` | Only one processor will run; photograph with `*memmap=1` |
| `no interrupts; polling` (xhci, nvme, ahci) | The device works but its interrupt does not arrive; if devices fail entirely, turn off IOMMU / DMA protection in the firmware |
| `timeout: in handoff` | The firmware did not release the USB controller; check "XHCI hand-off" |
| `need recover: USBSTS=…` repeating | USB controller error; photograph the controller's attach line |
| `selftest: … clock ticks` or `tsleep(250) took …` panic | Timekeeping is off; `*selftest=off` gets past it |
| `invalid mem-window`, `pcibarsize: invalid bar` | The PCI scan dropped a device's memory range; `*pcihinv=1` prints addresses |

`plan9.ini` settings for trouble (edit the file on the stick's first partition from any system):

| Setting | Effect |
|---|---|
| `*ncpu=1` | Use one processor |
| `*gopmode=WIDTHxHEIGHT` | Ask the firmware for this graphics mode |
| `*bootpause=seconds` | Pause after the machine summary |
| `*selftest=off` | Skip the kernel's boot self-test |
| `*nomsi=1` | Do not use message interrupts (drivers poll) |
| `*nohpet=1` | Calibrate against the ACPI timer instead of the HPET |
| `*memmap=1`, `*xsummary=1`, `*pcihinv=1` | Print the memory map, the allocator's holes, PCI addresses |
| `*nopcilist=1` | Leave the PCI list out |

Do not add `console=0`: without a serial port there is no `eia0` for bootrc to use.

### A shell without the root

At `bootargs is`, type `!rc` and Enter. This shell has only the few commands of the boot file system (`cat`, `ls`, `sed`, `grep`, `echo`, `dd`, `xd`) and the screen does not scroll back, so cut the output:

```
cat /dev/usb/ctl
ls /dev/sdU* /shr/usb
cat /dev/kmesg | sed 30q
```

`cat /dev/usb/ctl` lists every USB device the kernel found, with class (`storage`, `hid`, `hub`), speed and the five-digit name. Leave the shell with `exit`; to boot by hand answer `local!/dev/sdUxxxxx/fs`.

### Collecting information from rio

In the shell window:

```
cat /dev/kmesg
cat /dev/usb/ctl
cat /dev/sysstat
```

`/dev/kmesg` is everything the kernel printed. The up and down arrow keys scroll a rio window. `pci -v` lists every PCI device with its vendor and device numbers and, where 9front knows them, names; the line whose type is `net` is the Ethernet chip a driver is needed for.

To take the text to another machine, save it on the stick's FAT partition, which Linux can mount:

```
dossrv -f /dev/sdU*/esp esp
mount -c /srv/esp /n/esp
cat /dev/kmesg >/n/esp/kmesg.txt
cat /dev/usb/ctl >/n/esp/usb.txt
pci -v >/n/esp/pci.txt
unmount /n/esp
fshalt
```

On Linux the files are then in partition 1 of the stick (`fsck.fat` will remark that the free-cluster count is off after dossrv has written; that is harmless).

## plan9.ini on the stick

`tools/usb.ini`, with comments. What is in it and why:

- **No `console=`.** There is no serial port. Without it bootrc starts `kbdfs` on the screen with the USB keyboard only. (The kernel still copies its console to COM1 if the machine has one.)
- **No `mouseport=`.** The mouse is USB; `nusb/kb` feeds it to `/dev/mousein`.
- **`user=glenda`** answers the `user[glenda]:` question.
- **`nobootprompt=local!usbroot`** and **`fn#usbroot=…`** answer `bootargs is`. The root is `/dev/sdUxxxxx/fs`, where `xxxxx` is a hash `nusb/usbd` makes from the stick's vendor, product and serial number, so it cannot be written down in advance. bootrc's `local` method runs its argument as the file server when it is not a file, and rc defines a function from each environment variable named `fn#name`; so `plan9.ini` defines an rc function `usbroot` that waits up to 20 seconds for a `/dev/sdU*/fs` and starts the file server `fstype` names for it. If there is none, bootrc asks as usual.

To get the questions back, delete the `nobootprompt` line; bootrc then lists the disks and offers the stick's `fs` as the default, and Enter boots.
bootrc starts `kbdfs` and then `nusbrc` (which starts `nusb/kb`) before it asks anything, so the USB keyboard works at those questions.

## The test

`zig build test-usb -Dref=ref -Ddisk=…` builds the image and boots it in QEMU (`tools/usbtest.sh`) with OVMF, `-machine q35,i8042=off`, an xHCI controller, the image as a USB mass-storage device and the only disk, a USB keyboard and a USB tablet. It waits for rio, clicks in the shell window, types commands on the USB keyboard, writes a file on the root and reads the pointer position.

The image tested is the one for the stick, `plan9.ini` included. The test reads results from the serial line, which the real machine does not have: the kernel copies its console there, and the typed commands write to `/dev/eia0`. Nothing is sent over the serial line.

## Not yet tried on hardware

Everything here has run only in QEMU. Likely to differ on the real machine:

- **USB.** Only QEMU's xHCI has run. Real keyboards and mice are often low-speed devices, which have never run; neither have hubs with transaction translators, USB 3 hubs, 64-byte contexts, scratchpad buffers or the firmware hand-off. A real stick is slower than QEMU's and may take longer to appear; `usbroot` waits 20 seconds.
- **The firmware.** OVMF accepts the image with partition type `0xEF` and with `0x0C`, FAT32 and FAT16. Other firmware may be pickier; `tools/mkusb.py --esp-type 0c` makes a plain FAT32 partition instead.
- **The screen.** The mode is whatever the firmware left, probably the monitor's native one. rio's windows are placed for a small screen and text is small on a large one.
- **No network.** There is no driver for the board's network chip yet, so `stats` shows no Ethernet and nothing is configured.
