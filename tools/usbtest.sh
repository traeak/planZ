#!/bin/sh
# Boot the USB stick image (zig build usb-image) the way a PC without
# serial and PS/2 ports would: the image is the only disk, on a USB
# mass-storage device, with a USB keyboard and a USB tablet.  Checks
# that the firmware starts the loader from it, that 9front boots from
# its Plan 9 partition to vtfs's consoles without a key being pressed,
# that Ctl-Alt-2 and Ctl-Alt-1 switch them, that typed commands reach
# console 1's shell, that the root is the USB disk and can be written,
# that the pointer moves, that planZ's Zig programs on the boot volume
# (zig/run) install and match the stock programs, and that rio, typed
# at the shell, takes the console, with a command typed in its window.
#
# usage: usbtest.sh timeout-seconds image qemu-command...
#
# The image is opened as a snapshot and never changed.  The QEMU command
# must connect the serial port to stdio and must not have another disk.
#
# The image's plan9.ini has no console= line, so nothing typed on the
# serial line is read; keys and the pointer go through QEMU's monitor
# to the USB devices, as a person's would.  What the test reads comes
# from the serial line all the same: the kernel copies its console
# there, and the typed commands write their results to /dev/eia0.
# With USBSHOT=file.png in the environment a screenshot is kept there.

if [ $# -lt 3 ]; then
	echo "usage: $0 seconds image qemu-command..." >&2
	exit 2
fi
timeout=$1
image=$2
shift 2
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qmp="python3 -I $here/qmp.py $tmp/qmp"

# rio's background is the grey 0x777777.
cat >"$tmp/grey.py" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
f, i = [], 0
while len(f) < 4:
    j = i
    while not d[j:j + 1].isspace():
        j += 1
    f.append(d[i:j])
    i = j + 1
n = int(f[1]) * int(f[2])
grey = sum(1 for k in range(i, i + n * 3, 3) if d[k:k + 3] == b"\x77\x77\x77")
sys.exit(0 if grey * 5 > n else 1)
PY

# A console of vtfs with nothing on it but its shell's prompt: white,
# with a little black, all of it in the top rows.  The kernel's own
# console, which is on the screen until vtfs starts, is full of the
# boot's messages by then.
cat >"$tmp/fresh.py" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
f, i = [], 0
while len(f) < 4:
    j = i
    while not d[j:j + 1].isspace():
        j += 1
    f.append(d[i:j])
    i = j + 1
w, h = int(f[1]), int(f[2])
ink = [k // 3 for k in range(0, w * h * 3, 3) if d[i + k:i + k + 3] != b"\xff\xff\xff"]
sys.exit(0 if 20 <= len(ink) <= 1500 and max(ink) // w < 60 else 1)
PY

# Wait for vtfs: Ctl-Alt-2 then shows console 2, where nothing has
# been typed (before vtfs runs the keys do nothing: the screen is not
# such a console).  A line is typed there, and then back to console 1,
# which is asked later for both consoles' text and which is current.
cat >"$tmp/vt.sh" <<EOF2
n=0
until $qmp key ctrl alt 2 && sleep 1 && $qmp shot $tmp/two.ppm && python3 -I $tmp/fresh.py $tmp/two.ppm; do
	n=\$((n + 1))
	[ \$n -gt 90 ] && { echo "usb test: vtfs's console 2 did not appear" >&2; exit 1; }
	sleep 1
done
$qmp type 'echo on^two\\n' && sleep 1 && $qmp key ctrl alt 1 && sleep 2
EOF2

# rio, typed at console 1's shell: wait for its background.  Its one
# window is the current one.
cat >"$tmp/rio.sh" <<EOF2
$qmp type 'rio -i window\\n'
n=0
until $qmp shot $tmp/s.ppm && python3 -I $tmp/grey.py $tmp/s.ppm; do
	n=\$((n + 1))
	[ \$n -gt 60 ] && { echo "usb test: rio did not appear" >&2; exit 1; }
	sleep 1
done
sleep 3
$qmp type 'echo rio^usb >/dev/eia0\\n'
EOF2

sh "$here/bootchat.sh" "$timeout" \
	"usbroot: hjfs on /dev/sdU" "" \
	"init: starting /bin/rc" "@host sh $tmp/vt.sh" \
	"" "@host $qmp type 'echo key^ok >/dev/eia0\\n'" \
	"keyok" "@host $qmp type 'grep -s on[t]wo /dev/vt/2/text && ! grep -s on[t]wo /dev/vt/1/text && grep -s notcurrent /dev/vt/2/wctl && ! grep -s notcurrent /dev/vt/1/wctl && echo one^current >/dev/eia0\\n'" \
	"onecurrent" "@host $qmp type 'ls /dev/sdU*/fs /srv/boot >/dev/eia0\\n'" \
	"/srv/boot" "@host $qmp type 'echo planZ^usb >/usr/glenda/zt && cat /usr/glenda/zt >/dev/eia0\\n'" \
	"planZusb" "@host $qmp abs 16384 16384 , abs 16390 16390 , type 'dd -if /dev/mousein -bs 60 -count 1 -quiet 1 >/dev/eia0; echo >/dev/eia0\\n'" \
	"  640         400" "@host ${USBSHOT:+$qmp shot $USBSHOT} :" \
	"" "@host $qmp type 'dossrv -f /dev/sdU*/esp esp; mount -c /srv/esp /n/esp; rc /n/esp/zig/run >/dev/eia0\\n'" \
	"zig: all the same as stock, libctest ok" "@host sh $tmp/rio.sh" \
	"riousb" \
	-- "$@" -machine q35,i8042=off -device qemu-xhci \
	-drive "if=none,id=u0,format=raw,snapshot=on,file=$image" -device usb-storage,drive=u0 \
	-device usb-kbd -device usb-tablet \
	-qmp "unix:$tmp/qmp,server=on,wait=off"
