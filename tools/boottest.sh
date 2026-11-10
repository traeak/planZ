#!/bin/sh
# Boot the kernel in QEMU and wait for a line of serial output.
#
# usage: boottest.sh timeout-seconds 'expected text' qemu-command...
#
# The QEMU command must send the serial port to stdout.  Exits 0 as soon
# as the text appears, 1 on timeout or if QEMU exits without printing it.

if [ $# -lt 3 ]; then
	echo "usage: $0 seconds text qemu-command..." >&2
	exit 2
fi
timeout=$1
want=$2
shift 2

log=$(mktemp)
"$@" >"$log" 2>&1 </dev/null &
qemu=$!
trap 'kill $qemu 2>/dev/null; rm -f "$log"' EXIT

ticks=$((timeout * 10))
while [ $ticks -gt 0 ]; do
	if grep -q -F -- "$want" "$log"; then
		echo "boot test: found '$want'"
		exit 0
	fi
	if ! kill -0 $qemu 2>/dev/null; then
		break
	fi
	sleep 0.1
	ticks=$((ticks - 1))
done

# One last look, in case QEMU exited right after printing.
if grep -q -F -- "$want" "$log"; then
	echo "boot test: found '$want'"
	exit 0
fi
echo "boot test: '$want' not seen within ${timeout}s; serial output was:" >&2
cat "$log" >&2
exit 1
