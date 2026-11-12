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

## 3. Save everything to the stick

```
dossrv -f /dev/sdU*/esp esp
mount -c /srv/esp /n/esp
cat /dev/kmesg >/n/esp/kmesg.txt
pci -v >/n/esp/pci.txt
cat /dev/usb/ctl >/n/esp/usb.txt
cat /dev/sysstat >/n/esp/sysstat.txt
cp /tmp/ifstat1 /n/esp/ifstat1.txt
cp /tmp/ifstat2 /n/esp/ifstat2.txt
cat /net/ndb >/n/esp/ndb.txt
unmount /n/esp
fshalt
```

Wait for `done halting` before pulling the stick. On Linux the files
are in partition 1 of the stick. `fsck.fat` may say the free-cluster
count is wrong; that is harmless.

## 4. Optional

- [ ] `stats -lmc` in a new window: load, memory and context switches
      stay steady while idle.
- [ ] `cat /dev/sysstat` has one line per processor: 12 for the
      Ryzen 5 3600 with SMT on.

## 5. What to send back

- The files from step 3. Those are `kmesg.txt`, `pci.txt`, `usb.txt`,
  `sysstat.txt`, `ifstat1.txt`, `ifstat2.txt` and `ndb.txt`.
- A note on what happened in steps 1 and 2.
- A photo of the screen if anything panics or hangs.
