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

## Network through a USB adapter

9front drives USB Ethernet adapters from user space: `nusbrc` starts `nusb/ether` for the adapter, and it appears as `/net/etherUxxxxx` (`xxxxx` is the five-digit name of the device, as for the stick). The kernel only carries the USB transfers. In QEMU this works with its `usb-net` adapter, at full speed, on a root port and behind a USB 1.1 hub (`zig build test-usbnet`). No real adapter has been tried.

The adapter at hand is the Realtek RTL8153 (`0bda:8153`) built into the USB hub on the development machine. `nusbrc` on the stick knows that number and starts `nusb/ether` in its plain CDC mode; `nusb/ether` itself switches the chip from its first, vendor-specific configuration to its CDC one. **It sits behind the hub's USB 3 half (`0bda:0411`, SuperSpeed), and planZ has never run a USB 3 hub or a SuperSpeed network device.** Expect this to be the part that fails, and treat a failure as a useful report.

If you attach that hub to the test machine:

1. Plug it into a blue (USB 3) port on the back of the board before power-on. Plugging it in once rio is up is the second thing to try, not the first: in QEMU the kernel then finds the adapter, loses it when it is unplugged and finds it again, but with two `nusbrc` listeners running by then, QEMU's adapter (a communications-class device) is taken by `nusb/serial` before `nusb/ether` gets it. The RTL8153 should not be offered to `nusb/serial`; that has not been tried.
2. Boot to rio, click in the shell window and look:

   ```
   cat /dev/usb/ctl
   ls -d /net/ether*
   ```

   `/dev/usb/ctl` has two lines per endpoint; the second line of each device's `epN.0` names it. There should be
   - two `hub` lines for the dock: one on an `epN.0` line with `speed super` (`vid 0x0bda did 0x0411`) and one with `speed high` (`did 0x5411`);
   - one line for the adapter, `… vid 0x0bda did 0x8153 …`, on an `epN.0` line with `speed super` and a `hub` number that is the `N` of the SuperSpeed hub;
   - once `nusb/ether` has it, two more endpoints of the same `N`, `bulk r` and `bulk w` (QEMU's adapter shows one `bulk rw` instead);
   - and `ls` shows `/net/etherUxxxxx`.

   `nusb/serial: getdev: device or object already in use` on the console at start-up is harmless: the root's own `nusbrc` offers the adapter to `nusb/serial` after `nusb/ether` has taken it.
3. Get an address, naming the interface (a plain `ip/ipconfig` takes `ether0` if a driver for the board's own chip exists by then):

   ```
   cat /net/etherU*/addr
   ip/ipconfig ether /net/etherU*
   cat /net/ndb
   ```

   `addr` is the adapter's MAC address. `ipconfig` returns after a few seconds with a lease, and `/net/ndb` then shows `ip=`, `ipgw=` and `dns=`. `ndb/cs` and `ndb/dns` are already running (the profile starts them); nothing more is needed for names.
4. Use it, with the gateway address from `/net/ndb`:

   ```
   ip/ping -n 3 192.168.1.1
   hget http://9front.org/ | sed 5q
   hget https://9front.org/ | sed 5q
   cat /net/etherU*/stats
   ```

   `stats` counts packets `in:` and `out:`.

If it fails, the place it stops says where to look:

| What you see | Meaning |
|---|---|
| No `hub` line with `speed super`; `nusb/usbd: … sethubdepth`, `devctl hub` or `hub descriptor too small` on the console | The USB 3 hub did not attach |
| The hub is there, no `0x8153` line | The device behind the hub did not attach: the route through the hub, or its port status |
| `usbxhci …: hub slot N: …` in `/dev/kmesg` | The controller refused the command that marks the device as a hub |
| The `0x8153` line is there with `speed high` | It came up on the hub's USB 2 half; it should still work, at USB 2 speed |
| The `0x8153` line is there, no `/net/etherU…` | `nusb/ether` failed; run it by hand as below |
| `/net/etherU…` is there, `ipconfig` fails (`no success with DHCP`) | Packets do not get through; `stats` shows whether `out:` and `in:` move |
| Lease and ping work, `hget` stalls or the checksum of a download is wrong | Bulk transfers under load |

To see why `nusb/ether` fails, start it by hand with the adapter's `N` from `/dev/usb/ctl` (if `/net/etherU…` already exists the device is in use, and this only says so):

```
nusb/ether -d N
```

To see `nusb/usbd` attach the hub and the adapter step by step, add `usbdebug=-d` to `plan9.ini` on the stick; it prints a line per port event on the console at boot, so they are in the photograph or, if rio comes up, in what scrolls past before it.

Send back, saved as under "Collecting information from rio": `cat /dev/usb/ctl`, `cat /dev/kmesg`, `ls -l /net`, `cat /net/ndb`, `cat /net/etherU*/stats`, what `ip/ipconfig` and `nusb/ether -d N` printed, and from Linux on the development machine `lsusb -t` and `lsusb -v -d 0bda:8153` with the hub attached there (the configurations and endpoint sizes the chip really offers).

Things to know:

- **Without the USB 3 hub in the way.** A USB 2 port or cable makes the whole dock a high-speed device: hub `0x5411` only, the adapter behind it at `speed high`. A high-speed hub with a high-speed device behind it is close to what QEMU has run (its hub is full speed), so try a black port if the blue one fails.
- **QEMU's adapter is not this one.** It runs at full speed with 64-byte packets, announces itself as a communications device, and uses one endpoint number for both directions. The RTL8153 at SuperSpeed has 1024-byte packets, two endpoints, a configuration switch, and needs an empty packet after each frame that is a multiple of 1024 bytes long. None of that has run.
- **QEMU's own 8-port hub does not attach** (`nusb/usbd: … descr. too small`): its hub descriptor is one byte shorter than stock `nusb/usbd` requires for eight ports. QEMU adds such a hub by itself when the controller's ports run out, so give the controller more ports (`-device qemu-xhci,p2=8`) or a hub with `ports=7` or fewer. This is between QEMU and `nusb/usbd`, not the kernel; a real hub is not affected.

## The on-board Ethernet (RTL8125B)

`port/ether8125.zig` drives the board's Realtek RTL8125B. It has never run on the chip, so expect to send information back. With no other network card it is `ether0`.

At boot, look for `#l0: rtl8125: 1000Mbps port 0xFCC10000 irq 255 ea …` (the speed reads 100 if the link is down at that moment; `irq 255` is normal). Then, in the shell window:

```
ip/ipconfig
ip/ping -n 3 <your gateway>
cat /net/ether0/ifstat >/tmp/ifstat
cat /dev/kmesg >/tmp/kmesg
```

Copy both files to the stick's FAT partition as shown above and send them, whether or not it worked. In `kmesg` there should be `#l0: rtl8125: RTL8125B macv 0x64100000 pci rev 0x05 phy ramcode 0x…` and, a second or two later, `#l0: rtl8125: link up: 2500Mbps, phystatus 0x…`.

| What you see | Meaning | What to try or send |
|---|---|---|
| No `rtl8125` line at all | The PCI scan did not find `10ec:8125` | `pci -v` |
| `unknown mac 8125 xxxxxxxx` | A chip revision the driver does not know | The number |
| `reset failed: cr … mcucmd …` | The chip did not finish its reset | The line |
| `no interrupts; polling` | The interrupt does not arrive; the network works, slowly | `ifstat` |
| Never `link up` | Negotiation failed | Set `*rtl8125nophy=1` in `plan9.ini` and try again; send `ifstat` from both |
| Link up, no lease | Transmit or receive ring problem | `ifstat` taken twice, a few seconds apart |
| Works, then stops | | `ifstat`; `resets` above 1 means the driver restarted the chip |

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
- **USB Ethernet.** Only QEMU's full-speed adapter has run. See "Network through a USB adapter" for what a real one, behind a USB 3 hub, adds.
