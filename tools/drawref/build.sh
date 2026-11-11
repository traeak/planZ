#!/bin/sh
# Build 9front's libdraw/libmemdraw/libmemlayer for the host and run the
# reference program whose output is the `want` text of the Zig tests.
# Needs gcc.  From the top of planZ:
#	tools/drawref/build.sh /path/to/9front/sys
#	tools/drawref/cref x >/tmp/refx.txt	(x: leave out XRGB32's unused byte)
#	python3 tools/drawref/want.py /tmp/refx.txt src/kernel
# The last step rewrites the `want` text at the end of the test files.
S=${1:?usage: build.sh /path/to/9front/sys}
S=$(cd "$S" && pwd) || exit 1
cd "$(dirname "$0")" || exit 1
CF="-std=gnu2x -fplan9-extensions -fwrapv -fno-strict-aliasing -O1 -w -Iinclude"
mkdir -p obj; rm -f obj/*.o
for f in $(cat srcs.txt) libmemdraw/string.c libmemdraw/defont.c libmemdraw/subfont.c libdraw/defont.c; do
	gcc $CF -c $S/src/$f -o obj/$(echo $f | tr / _ | sed 's/\.c$/.o/') || exit 1
done
gcc $CF -c main.c -o obj/main.o && gcc -O1 -w -c support.c -o obj/support.o && gcc obj/*.o -o cref
