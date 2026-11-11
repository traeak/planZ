#!/bin/sh
# Make rio's console window the current one, so that what is typed on
# the serial line reaches its shell.
#
# usage: riofocus.sh qmp-socket
#
# With console= in plan9.ini, 9front's riostart opens three windows:
# stats, a shell, and "console", a shell whose output is copied to the
# serial port.  Serial input is merged with the keyboard and goes to
# the current window, and rio makes the last window created current.
# The three are created by background jobs that race, so the console
# window is not always last: stock 9front loses the race every time
# under KVM, planZ now and then.  Keys cannot change rio's current
# window; a click can.
#
# This waits until rio has drawn its grey background, then clicks
# twice, a second apart, at (600,100) through QEMU's monitor.  rio
# places a new window at (32+16i, 32+16i), 600x400, for i = 0, 1, 2
# here, and the shell window starts at y=130, so that point is inside
# the console window and no other, whatever the order.  Needs a USB
# tablet in the QEMU command (absolute positions) and a screen of at
# least 664x464.

here=$(cd "$(dirname "$0")" && pwd)
sock=${1:?usage: riofocus.sh qmp-socket}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qmp="python3 -I $here/qmp.py $sock"

# Prints the click position in the tablet's 0..32767 units when the
# screen is mostly rio's background (0x777777); fails otherwise.
cat >"$tmp/where.py" <<'PY'
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
n = w * h
grey = sum(1 for k in range(i, i + n * 3, 3) if d[k:k + 3] == b"\x77\x77\x77")
if grey * 5 <= n:
    sys.exit(1)
print(600 * 32767 // (w - 1), 100 * 32767 // (h - 1))
PY

tries=0
until pos=$($qmp shot "$tmp/s.ppm" && python3 -I "$tmp/where.py" "$tmp/s.ppm"); do
	tries=$((tries + 1))
	if [ $tries -ge 60 ]; then
		echo "riofocus: rio has not drawn its screen" >&2
		exit 1
	fi
	sleep 1
done
# Let riostart's windows all appear before choosing one.
sleep 2
set -- $pos
$qmp abs "$1" "$2" , btn left click || exit 1
sleep 1
$qmp abs "$1" "$2" , btn left click
