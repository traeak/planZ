#!/bin/sh
# Boot stock 9front from the disk image, fetch planZ's Zig programs
# (zig-out/user/bin, from `zig build user`) and tools/usbzig.rc from a
# web server on the host's loopback address (see nettest.sh), and run
# the script, which compares each program with the stock one of the
# same name and runs libctest.  It is the script the USB stick carries
# as zig/run.
#
# usage: zusertest.sh timeout-seconds bindir qemu-command...
#
# The QEMU command must connect the serial port to stdio and have a
# network card on user-mode networking and the 9front disk.
# Needs python3 and openssl on the host.

if [ $# -lt 3 ]; then
	echo "usage: $0 seconds bindir qemu-command..." >&2
	exit 2
fi
timeout=$1
bindir=$2
shift 2
here=$(cd "$(dirname "$0")" && pwd)

tmp=$(mktemp -d)
mkdir "$tmp/tls" "$tmp/www"
cp "$bindir"/* "$tmp/www/"
cp "$here/usbzig.rc" "$tmp/www/run"
# the names go in a file the guest fetches, which keeps the typed
# command short
(cd "$bindir" && ls) >"$tmp/www/list"
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=planz-test \
	-keyout "$tmp/tls/key" -out "$tmp/tls/crt" >/dev/null 2>&1; then
	echo "zuser test: openssl could not make a certificate" >&2
	rm -rf "$tmp"
	exit 1
fi
python3 -I -u "$here/nettestd.py" "$tmp/www" "$tmp/tls/crt" "$tmp/tls/key" >"$tmp/ports" 2>"$tmp/err" &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$tmp"' EXIT
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	[ -n "$(sed -n 's/^http //p' "$tmp/ports")" ] && break
	sleep 0.3
done
port=$(sed -n 's/^http //p' "$tmp/ports")
if [ -z "$port" ]; then
	echo "zuser test: the web server did not start" >&2
	cat "$tmp/err" >&2
	exit 1
fi

case " $* " in
*qemu-xhci*) tablet="-device usb-tablet" ;;
*) tablet="-device qemu-xhci -device usb-tablet" ;;
esac

url=http://10.0.2.2:$port
get="mkdir -p /tmp/zsrc; for(p in \`{hget $url/list}) hget $url/\$p >/tmp/zsrc/\$p; hget $url/run >/tmp/zrun; echo fetch^ok"

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "ip/ipconfig && webfs && echo net^ok" \
	"netok" "$get" \
	"fetchok" "rc /tmp/zrun /tmp/zsrc" \
	"zig: all the same as stock, libctest ok" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off"
