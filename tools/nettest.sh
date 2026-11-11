#!/bin/sh
# Boot stock 9front from the disk image and use the network: a DHCP
# lease from QEMU's user-mode network, a ping of the gateway, and a
# file fetched from a web server started here on the host's loopback
# address (the guest reaches it as 10.0.2.2), over plain HTTP and then
# over TLS 1.2 with three cipher suites.  The SHA-1 of each copy must
# match.  Nothing outside this machine is contacted.
#
# usage: nettest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have a
# network card on user-mode networking and the 9front disk.
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
	echo "net test: openssl could not make a certificate" >&2
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
	echo "net test: the web server did not start" >&2
	cat "$tmp/err" >&2
	exit 1
fi

# Each download prints its checksum after a tag, so that one answer is
# not taken for the next.
get() { echo "echo $1 \`{hget $2://10.0.2.2:$(port $1)/big.bin | sha1sum}"; }

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"starting /bin/rc" "ip/ipconfig && ndb/cs && echo lease^ok" \
	"leaseok" "grep -c 'ip=10.0.2.15' /net/ndb && echo addr^ok" \
	"addrok" "ip/ping -n 2 10.0.2.2 && echo ping^ok" \
	"pingok" "webfs && $(get http http)" \
	"http $sum" "$(get chacha https)" \
	"chacha $sum" "$(get gcm https)" \
	"gcm $sum" "$(get cbc https)" \
	"cbc $sum" \
	-- "$@"
