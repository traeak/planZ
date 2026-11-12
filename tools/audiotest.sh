#!/bin/sh
# Boot stock 9front from the disk image and play a tone through the
# HDA driver: QEMU emulates an Intel HDA controller with a codec and
# writes what it plays to a wav file, which is checked here afterwards
# (tools/audiocheck.py: 440 Hz, long enough, both channels).  The tone
# is fetched from a web server on the host's loopback address (see
# nettest.sh).  On the way it reads audiostat and volume, sets the
# volume, and opens /dev/audio twice for writing, which must fail.
#
# usage: audiotest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have a
# network card on user-mode networking and the 9front disk.  The HDA
# controller and codec are added here; AUDIODEV in the environment
# replaces them (e.g. "ich9-intel-hda hda-output").
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
python3 -I "$here/audiocheck.py" make "$tmp/www/tone.wav" || exit 1
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=planz-test \
	-keyout "$tmp/tls/key" -out "$tmp/tls/crt" >/dev/null 2>&1; then
	echo "audio test: openssl could not make a certificate" >&2
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
	echo "audio test: the web server did not start" >&2
	cat "$tmp/err" >&2
	exit 1
fi

ctlr=intel-hda
codec=hda-duplex
if [ -n "$AUDIODEV" ]; then
	ctlr=${AUDIODEV%% *}
	codec=${AUDIODEV#* }
fi
case " $* " in
*qemu-xhci*) tablet="-device usb-tablet" ;;
*) tablet="-device qemu-xhci -device usb-tablet" ;;
esac

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "grep -s outpath /dev/audiostat && echo stat^ok" \
	"statok" "cat /dev/volume && echo master 50 > /dev/volume && grep master /dev/volume && echo recgain 30 70 > /dev/volume && grep recgain /dev/volume && echo vol^ok" \
	"volok" "{sleep 3} > /dev/audio & sleep 1; echo x > /dev/audio" \
	"device is busy" "sleep 3; ip/ipconfig && webfs && echo net^ok" \
	"netok" "echo master 100 > /dev/volume; hget http://10.0.2.2:$port/tone.wav | audio/wavdec > /dev/audio && sleep 1 && echo play^ok" \
	"playok" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off" \
	-audiodev "wav,id=snd0,path=$tmp/out.wav" -device "$ctlr" -device "$codec,audiodev=snd0" || {
	echo "audio test: the conversation failed; see above" >&2
	exit 1
}
python3 -I "$here/audiocheck.py" check "$tmp/out.wav"
