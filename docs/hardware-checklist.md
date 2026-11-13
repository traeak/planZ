# Checking planZ on the test machine

What to do once the stick has booted to rio on the Ryzen 5 3600 /
B550i machine. Type everything in a rio shell window. The up and down
arrow keys scroll a window. Background and failure tables are in
`real-hardware.md`.

## 1. Keyboard and mouse

- [ ] Typing in the window works. (Already seen on the first boot.)
- [ ] The pointer follows the mouse.
- [ ] Right-click on the grey background shows rio's menu. Choose *New*,
      drag out a rectangle, and a second shell window opens.
- [ ] Left-click switches between windows; typing goes to the one clicked.

## 2. On-board Ethernet (RTL8125B)

The driver has never run on this chip; this is the main thing to test.
Plug a cable into the board's port, then:

```
ip/ipconfig
cat /net/ndb
ip/ping -n 3 8.8.8.8
cat /net/ether0/ifstat >/tmp/ifstat1
```

- [ ] `ip/ipconfig` returns within a few seconds without an error.
- [ ] `/net/ndb` shows `ip=`, `ipgw=` and `dns=`.
- [ ] `ping` gets replies.

Whether it works or not, wait five seconds and take a second snapshot:

```
cat /net/ether0/ifstat >/tmp/ifstat2
```

If there is never a link (`ifstat` shows no `link up`), add
`*rtl8125nophy=1` to `plan9.ini` on the stick, boot again and repeat
this step. Keep the files from both boots.

## 3. Sound (on-board HD Audio)

The driver is 9front's, ported; it has only run in QEMU so far. Plug
speakers or headphones into the green jack at the back, then:

```
cat /dev/audiostat >/tmp/audiostat
cat /dev/volume >/tmp/volume
grep -e '^codec' -e path /tmp/audiostat
echo 30 >/dev/volume
dd -if /dev/random -bs 4096 -count 40 >/dev/audio
```

- [ ] `grep` shows a `codec` line and an `outpath` line.
- [ ] The last command plays about a second of soft hiss.

If nothing is heard, look in `/tmp/audiostat` for the `pin` lines
marked `out`. Each one says where the jack is (`rear`, `front`) and its
colour. Try each pin number N in turn and play the hiss again. Front
headphones are worth trying too:

```
echo pin N >/dev/audioctl
dd -if /dev/random -bs 4096 -count 40 >/dev/audio
```

Note which pin numbers worked, if any.

## 4. Zig programs

planZ's user programs written in Zig are on the stick, in `zig/bin`:
the commands ported so far (`build.zig`'s `zcmds` lists them), the
`retest` and `fltest` halves that compare libregexp and the float
formats with stock libc, and `libctest`, which checks the library under
them. The script copies them to `/tmp/zig` and runs each one beside the
stock 9front program of the same name. If anything differs, it shows
how:

```
dossrv -f /dev/sdU*/esp esp
mount -c /srv/esp /n/esp
rc /n/esp/zig/run
```

- [ ] The last line is `zig: all the same as stock, libctest ok`.

Afterwards they can be run as `/tmp/zig/ls` and so on.

## 5. Save everything to the stick

If step 4 was skipped, mount the stick first:

```
dossrv -f /dev/sdU*/esp esp
mount -c /srv/esp /n/esp
```

Then:

```
cat /dev/kmesg >/n/esp/kmesg.txt
pci -v >/n/esp/pci.txt
cat /dev/usb/ctl >/n/esp/usb.txt
cat /dev/sysstat >/n/esp/sysstat.txt
cp /tmp/ifstat1 /n/esp/ifstat1.txt
cp /tmp/ifstat2 /n/esp/ifstat2.txt
cat /net/ndb >/n/esp/ndb.txt
cp /tmp/audiostat /n/esp/audiostat.txt
cp /tmp/volume /n/esp/volume.txt
cp /tmp/zig.txt /n/esp/zig.txt
unmount /n/esp
fshalt
```

Wait for `done halting` before pulling the stick. On Linux the files
are in partition 1 of the stick. `fsck.fat` may say the free-cluster
count is wrong; that is harmless.

## 6. Optional

- [ ] `stats -lmc` in a new window: load, memory and context switches
      stay steady while idle.
- [ ] `cat /dev/sysstat` has one line per processor: 12 for the
      Ryzen 5 3600 with SMT on.

## 7. What to send back

- The files from step 5. Those are `kmesg.txt`, `pci.txt`, `usb.txt`,
  `sysstat.txt`, `ifstat1.txt`, `ifstat2.txt`, `ndb.txt`,
  `audiostat.txt`, `volume.txt` and `zig.txt`.
- A note on what happened in steps 1 to 3, including which pins played
  sound.
- A photo of the screen if anything panics or hangs.
