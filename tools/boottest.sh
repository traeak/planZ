#!/bin/sh
# Boot the kernel in QEMU and wait for lines of serial output.
#
# usage: boottest.sh timeout-seconds 'expected text' qemu-command...
#
# Several texts may be given separated by '|'; all must appear, in any
# order.  The QEMU command must send the serial port to stdout.  Exits 0
# as soon as every text has appeared, 1 on timeout or if QEMU exits
# first.  A kernel panic that was not asked for ends the wait at once.

if [ $# -lt 3 ]; then
	echo "usage: $0 seconds 'text[|text...]' qemu-command..." >&2
	exit 2
fi
timeout=$1
want=$2
shift 2

log=$(mktemp)
"$@" >"$log" 2>&1 </dev/null &
qemu=$!
trap 'kill $qemu 2>/dev/null; rm -f "$log"' EXIT

# All of the wanted texts are in the log.
seen() {
	rest=$want
	while [ -n "$rest" ]; do
		one=${rest%%|*}
		grep -a -q -F -- "$one" "$log" || return 1
		case $rest in
		*'|'*) rest=${rest#*|} ;;
		*) rest= ;;
		esac
	done
	return 0
}

ticks=$((timeout * 10))
while [ $ticks -gt 0 ]; do
	if seen; then
		echo "boot test: found '$want'"
		exit 0
	fi
	# Not waiting for a panic, and there is one: no point going on.
	case $want in
	*panic:*) ;;
	*) grep -a -q -F -- "panic: " "$log" && break ;;
	esac
	if ! kill -0 $qemu 2>/dev/null; then
		break
	fi
	sleep 0.1
	ticks=$((ticks - 1))
done

# One last look, in case QEMU exited right after printing.
if seen; then
	echo "boot test: found '$want'"
	exit 0
fi
echo "boot test: '$want' not seen within ${timeout}s; serial output was:" >&2
cat "$log" >&2
exit 1
