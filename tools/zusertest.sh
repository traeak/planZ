#!/bin/sh
# Boot stock 9front from the disk image, fetch planZ's Zig programs
# (zig-out/user/bin, from `zig build user`) from a web server on the
# host's loopback address (see nettest.sh), and run each beside the
# stock program of the same name with the same arguments: standard
# output, and for the error cases standard error, must be the same
# byte for byte.  Then run libctest, which checks the rest of the
# library and prints "libctest ok".
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
mkdir "$tmp/tls"
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=planz-test \
	-keyout "$tmp/tls/key" -out "$tmp/tls/crt" >/dev/null 2>&1; then
	echo "zuser test: openssl could not make a certificate" >&2
	rm -rf "$tmp"
	exit 1
fi
python3 -I -u "$here/nettestd.py" "$bindir" "$tmp/tls/crt" "$tmp/tls/key" >"$tmp/ports" 2>"$tmp/err" &
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

# t NAME compares /tmp/a (the Zig program's output) with /tmp/b (the
# stock program's) and says "same" or shows both.
fn='fn t { if(cmp -s /tmp/a /tmp/b) echo same^$1; if not { echo DIFF $1; cat /tmp/a; echo ---; cat /tmp/b } }'
get="for(p in echo cat ls wc libctest) hget http://10.0.2.2:$port/\$p > /tmp/z\$p; chmod +x /tmp/z*; echo fetch^ok"

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "ip/ipconfig && webfs && echo net^ok" \
	"netok" "$fn; $get" \
	"fetchok" "/tmp/zecho hello 'a b' -x >/tmp/a; echo hello 'a b' -x >/tmp/b; t echo1" \
	"sameecho1" "/tmp/zecho -n x y >/tmp/a; echo -n x y >/tmp/b; t echo2" \
	"sameecho2" "/tmp/zecho >/tmp/a; echo >/tmp/b; t echo3" \
	"sameecho3" "/tmp/zcat /lib/namespace /amd64/bin/rc >/tmp/a; cat /lib/namespace /amd64/bin/rc >/tmp/b; t cat1" \
	"samecat1" "/tmp/zcat </lib/namespace >/tmp/a; cat </lib/namespace >/tmp/b; t cat2" \
	"samecat2" "/tmp/zcat /nope >[2]/tmp/a; cat /nope >[2]/tmp/b; t cat3" \
	"samecat3" "/tmp/zwc /lib/namespace /amd64/bin/rc >/tmp/a; wc /lib/namespace /amd64/bin/rc >/tmp/b; t wc1" \
	"samewc1" "/tmp/zwc -lwrbc /amd64/bin/rc </lib/namespace >/tmp/a; wc -lwrbc /amd64/bin/rc </lib/namespace >/tmp/b; t wc2" \
	"samewc2" "/tmp/zwc -c </lib/namespace >/tmp/a; wc -c </lib/namespace >/tmp/b; t wc3" \
	"samewc3" "cd /; /tmp/zls >/tmp/a; ls >/tmp/b; cd; t ls1" \
	"samels1" "/tmp/zls /dev /env/home /bin/ip /lib/namespace >/tmp/a; ls /dev /env/home /bin/ip /lib/namespace >/tmp/b; t ls2" \
	"samels2" "/tmp/zls -F /amd64/bin >/tmp/a; ls -F /amd64/bin >/tmp/b; t ls3" \
	"samels3" "/tmp/zls -ds /lib /amd64/bin/rc >/tmp/a; ls -ds /lib /amd64/bin/rc >/tmp/b; t ls4" \
	"samels4" "/tmp/zls -tr /lib >/tmp/a; ls -tr /lib >/tmp/b; t ls5" \
	"samels5" "/tmp/zls -pq /lib/ndb >/tmp/a; ls -pq /lib/ndb >/tmp/b; t ls6" \
	"samels6" "/tmp/zls /nope >[2]/tmp/a; ls /nope >[2]/tmp/b; t ls7" \
	"samels7" "/tmp/zlibctest" \
	"libctest ok" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off"
