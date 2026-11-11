#!/bin/sh
# Boot stock 9front from the disk image and use the network through a
# USB Ethernet adapter: QEMU's usb-net on an xHCI controller, which
# stock nusbrc hands to nusb/ether as a CDC Ethernet device.  nusb/ether
# serves it as /net/etherUxxxxx, so every packet crosses the kernel's
# USB stack (bulk in and out) and '#σ'.  A DHCP lease, a ping of the
# gateway, and a 3MB file fetched over plain HTTP and over TLS from the
# web server of nettest.sh's kind, started here on the host's loopback
# address; the SHA-1 of each copy must match.  Nothing outside this
# machine is contacted.
#
# usage: usbnettest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk; the xHCI controller and the adapter are added here.  It
# may have another network card: the USB interface is named to
# ip/ipconfig, and the test checks that the IP interface is on it.
# With USBNETDEV in the environment, its words replace the QEMU
# arguments for the adapter (to put it behind a hub, say); the netdev
# is "un0".
# Needs python3 and openssl on the host.

if [ $# -lt 2 ]; then
	echo "usage: $0 seconds qemu-command..." >&2
	exit 2
fi
timeout=$1
shift
here=$(cd "$(dirname "$0")" && pwd)

tmp=$(mktemp -d)
mkdir "$tmp/www" "$tmp/tls"
head -c 3000000 /dev/urandom >"$tmp/www/big.bin"
sum=$(sha1sum "$tmp/www/big.bin" | cut -d' ' -f1)

# A certificate for the occasion; 9front's webfs does not check it.
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=planz-test \
	-keyout "$tmp/tls/key" -out "$tmp/tls/crt" >/dev/null 2>&1; then
	echo "usb net test: openssl could not make a certificate" >&2
	rm -rf "$tmp"
	exit 1
fi

python3 -I -u "$here/nettestd.py" "$tmp/www" "$tmp/tls/crt" "$tmp/tls/key" >"$tmp/ports" 2>"$tmp/err" &
server=$!
trap 'kill $server 2>/dev/null; rm -rf "$tmp"' EXIT
port() { sed -n "s/^$1 //p" "$tmp/ports"; }
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
	[ -n "$(port cbc)" ] && break
	sleep 0.3
done
if [ -z "$(port cbc)" ]; then
	echo "usb net test: the web server did not start" >&2
	cat "$tmp/err" >&2
	exit 1
fi

# Each download prints its checksum after a tag, so that one answer is
# not taken for the next.
get() { echo "echo $1 \`{hget $2://10.0.2.2:$(port $1)/big.bin | sha1sum}"; }

# $USBNETDEV is split into words on purpose.
sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "grep -c '^comms.* xhci' /dev/usb/ctl && test -r /net/etherU*/addr && echo ether^ok" \
	"etherok" "ip/ipconfig ether /net/etherU* && ndb/cs && echo lease^ok" \
	"leaseok" "grep -c 'ip=10.0.2.15' /net/ndb && grep -c 'device /net/etherU' /net/ipifc/0/status && echo addr^ok" \
	"addrok" "ip/ping -n 2 10.0.2.2 && echo ping^ok" \
	"pingok" "webfs && $(get http http)" \
	"http $sum" "$(get chacha https)" \
	"chacha $sum" "cat /net/etherU*/stats && echo stats^ok" \
	"statsok" \
	-- "$@" -device qemu-xhci -device usb-tablet -netdev user,id=un0 \
	${USBNETDEV:--device usb-net,netdev=un0} \
	-qmp "unix:$tmp/qmp,server=on,wait=off"
