#!/bin/sh
# Boot stock 9front from the disk image to its default session (see
# tools/session): vtfs's consoles in place of rio.  With console=0 its
# first console is copied to the serial line, and kbdfs merges what
# comes in on the serial line with the keyboard, so the conversation is
# held there, with console 1 current.  Keys go through QEMU's monitor.
# Checked:
#   - no rio; vtfs running; a command typed on the keyboard runs;
#   - Ctl-Alt-2 shows console 2 (another picture) and what is typed
#     goes there; Ctl-Alt-1 shows console 1 again, the same picture as
#     before;
#   - Ctl-Alt-Left and -Right wrap round: 1, 4, 3, then 4 and 1;
#   - the kernel's messages are on console 4;
#   - Delete interrupts the command running on console 1;
#   - console 2's rc, exited, is started again;
#   - rio, started from console 2's shell, draws there (mostly its
#     grey), a command typed in its window runs, and its menu comes up
#     under button 3; console 1 looks the same before and after a visit
#     to rio's; what is typed on console 1 meanwhile does not reach
#     rio, whose picture is the same afterwards; rio holds the
#     console's kbd open (a second open is refused);
#   - rio killed, console 2 shows its text again and its shell goes on;
#   - the mouse on console 3's text: button 1 dragged along the first
#     line marks it (the picture changes) and it is in /dev/snarf; a
#     double click on the second line takes its word; button 2 types
#     it after what was typed; the pointer shows when the mouse
#     moves and goes when a key is typed; /dev/snarf can be written.
# The mouse positions are for a screen of 1280x800 and the 8x16 font.
# Each console's text is read from /dev/vt/N/text on console 1.
#
# usage: vttest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk; a USB tablet is added for the mouse (absolute positions); the boot volume's plan9.ini must say console=0 and no
# session= other than vt.  With VTSHOT=dir in the environment the
# screenshots are kept there.

if [ $# -lt 2 ]; then
	echo "usage: $0 seconds qemu-command..." >&2
	exit 2
fi
timeout=$1
shift
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qmp="python3 -I $here/qmp.py $tmp/qmp"
shots=${VTSHOT:-$tmp}
case " $* " in
*qemu-xhci*) tablet="-device usb-tablet" ;;
*) tablet="-device qemu-xhci -device usb-tablet" ;;
esac

# pix.py frac file rrggbb min max: the percentage of the screen that
# has that colour must be within min..max.
# pix.py diff a b min: at least min pixels must differ.
cat >"$tmp/pix.py" <<'EOF'
import sys
def ppm(name):
    d = open(name, "rb").read()
    f, i = [], 0
    while len(f) < 4:
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        f.append(d[i:j])
        i = j + 1
    return int(f[1]) * int(f[2]), d[i:]
if sys.argv[1] == "frac":
    n, d = ppm(sys.argv[2])
    c = bytes.fromhex(sys.argv[3])
    pct = sum(1 for k in range(0, n * 3, 3) if d[k:k + 3] == c) * 100 // n
    print("vt test: %d%% of the screen is %s" % (pct, sys.argv[3]))
    sys.exit(0 if int(sys.argv[4]) <= pct <= int(sys.argv[5]) else 1)
else:
    n, a = ppm(sys.argv[2])
    m, b = ppm(sys.argv[3])
    k = sum(1 for k in range(0, n * 3, 3) if a[k:k + 3] != b[k:k + 3])
    print("vt test: %d pixels differ" % k)
    sys.exit(0 if n == m and k >= int(sys.argv[4]) else 1)
EOF
pix="python3 -I $tmp/pix.py"

# console 1, console 2, console 1 again
switch="sleep 1; $qmp shot $shots/one.ppm"
switch="$switch && $qmp key ctrl alt 2 , type 'echo two^two\\n' && sleep 2 && $qmp shot $shots/two.ppm"
switch="$switch && $qmp key ctrl alt 1 && sleep 2 && $qmp shot $shots/again.ppm"
switch="$switch && cmp -s $shots/one.ppm $shots/again.ppm && ! cmp -s $shots/one.ppm $shots/two.ppm"
switch="$switch && echo vt test: console 1 looks the same after a switch"
# 1, 4, 3: typed there; 4, 1
wrap="$qmp key ctrl alt left , key ctrl alt left , type 'echo three^three\\n'"
wrap="$wrap && sleep 1 && $qmp key ctrl alt right , key ctrl alt right"
# console 2's rc exits and comes back
again="$qmp key ctrl alt 2 , type 'exit\\n' && sleep 3 && $qmp type 'echo again^two\\n' && sleep 1 && $qmp key ctrl alt 1"
# rio on console 2 (its background is the grey 0x777777), with one
# window, which is current: a command typed there; its menu under
# button 3 on the background, away from the window
rio="$qmp key ctrl alt 2 , type 'rio -i window\\n' && sleep 6 && $qmp shot $shots/rio.ppm"
rio="$rio && $pix frac $shots/rio.ppm 777777 20 100"
rio="$rio && $qmp type 'echo rio^key >/tmp/vtrio\\n' && sleep 2"
rio="$rio && $qmp abs 26000 26000 && sleep 1 && $qmp shot $shots/nomenu.ppm"
rio="$rio && $qmp btn right down && sleep 1 && $qmp shot $shots/menu.ppm"
rio="$rio && $qmp abs 30000 30000 , btn right up , abs 26000 26000 && sleep 1"
rio="$rio && $pix diff $shots/nomenu.ppm $shots/menu.ppm 500 && $qmp shot $shots/rio2.ppm"
# console 1 before; rio's console; console 1 again, typed on, the
# mouse moved and put back; rio's console as it was
visit="$qmp shot $shots/c1.ppm && $qmp key ctrl alt 2 && sleep 2"
visit="$visit && $qmp key ctrl alt 1 && sleep 2 && $qmp shot $shots/c1again.ppm && cmp -s $shots/c1.ppm $shots/c1again.ppm"
visit="$visit && echo vt test: console 1 looks the same after rio"
visit="$visit && $qmp type 'echo on^one >/tmp/vtone\\n' , abs 9000 9000 , btn left click , abs 26000 26000 && sleep 2"
visit="$visit && $qmp key ctrl alt 2 && sleep 2 && $qmp shot $shots/rio3.ppm && cmp -s $shots/rio2.ppm $shots/rio3.ppm"
visit="$visit && echo vt test: rio looks the same after console 1 && $qmp key ctrl alt 1"
# rio gone: console 2 is text again (mostly white), and its shell runs
gone="sleep 3; $qmp key ctrl alt 2 && sleep 2 && $qmp shot $shots/text2.ppm && $pix frac $shots/text2.ppm ffffff 80 100"
gone="$gone && $qmp type 'echo text^back\\n' && sleep 1 && $qmp key ctrl alt 1"
# console 3 holds "cpu% echo three^three", "threethree" and a prompt.
# Drag along the first line, from its start to far right of its end.
drag="$qmp key ctrl alt 3 && sleep 1 && $qmp abs 153 492 && sleep 1 && $qmp shot $shots/unmarked.ppm"
drag="$drag && $qmp btn left down , abs 20000 492 , abs 30743 492 && sleep 1 && $qmp shot $shots/marked.ppm"
drag="$drag && $qmp btn left up && $pix diff $shots/unmarked.ppm $shots/marked.ppm 1500 && $qmp key ctrl alt 1"
# A double click on the second line's word; then type, and button 2.
word="$qmp key ctrl alt 3 && sleep 1 && $qmp abs 615 1148 , btn left click , btn left click && sleep 1"
word="$word && $qmp type 'echo got^' , btn middle click , type '\\n' && sleep 1"
# The pointer: none after a key, there once the mouse moves, gone
# again with the next key (an x and its erasure: the same text).
word="$word && $qmp shot $shots/noptr.ppm && $qmp abs 20000 20000 && sleep 1 && $qmp shot $shots/ptr.ppm"
word="$word && $qmp type x , key backspace && sleep 1 && $qmp shot $shots/noptr2.ppm"
word="$word && cmp -s $shots/noptr.ppm $shots/noptr2.ppm && ! cmp -s $shots/noptr.ppm $shots/ptr.ppm"
word="$word && echo vt test: the pointer shows when the mouse moves and goes when a key is typed && $qmp key ctrl alt 1"

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"cpu% " "  echo go^on" \
	"goon" "if(! ps | grep -s ' rio\$') echo no^rio" \
	"norio" "ps | grep -s ' vtfs\$' && echo vt^runs" \
	"vtruns" "@host $qmp type 'echo key^ok\\n'" \
	"keyok" "@host $switch" \
	"" "grep -s twotwo /dev/vt/2/text && echo found^two" \
	"foundtwo" "@host $wrap" \
	"" "grep -s threethree /dev/vt/3/text && grep -s ' current ' /dev/wctl && echo found^three" \
	"foundthree" "echo hello^kernel >'#c/cons'; sleep 1; grep -s hellokernel /dev/vt/4/text && echo kernel^ok" \
	"kernelok" "sleep 100" \
	"" "@host sleep 2; $qmp key delete" \
	"" "echo after^int" \
	"afterint" "@host $again" \
	"" "grep -s againtwo /dev/vt/2/text && echo restart^ok" \
	"restartok" "@host $rio && $qmp key ctrl alt 1" \
	"" "cat /tmp/vtrio" \
	"riokey" "@host $visit" \
	"" "cat /tmp/vtone && ps | grep -s ' rio\$' && echo rio^runs" \
	"rioruns" "cat /dev/vt/2/kbd >[2=1] | grep -c 'in use' | sed 's/^1\$/kbd/;s/\$/held/'" \
	"kbdheld" "kill rio | rc; echo rio^killed" \
	"riokilled" "@host $gone" \
	"" "grep -s textback /dev/vt/2/text && echo text^ok" \
	"textok" "@host $drag" \
	"" "cat /dev/snarf | tr -d ' %^'; echo" \
	"cpuechothreethree" "@host $word" \
	"" "~ \`{cat /dev/snarf} three^three && grep -s got^three^three /dev/vt/3/text && echo paste^ok" \
	"pasteok" "echo -n snarf^written >/dev/snarf; cat /dev/snarf; echo" \
	"snarfwritten" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off"
