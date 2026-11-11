#!/bin/sh
# Build 9front's libc pool allocator (libc/port/pool.c) for the host
# with the type sizes of Plan 9 on amd64, and the program that replays
# on it the operations of src/kernel/pooltest.zig.  Needs gcc; Linux
# (the arenas are mapped at a fixed address so that both sides make
# their alignment decisions on the same addresses).  From the top of
# planZ:
#	tools/poolref/build.sh /path/to/9front/sys
#	tools/poolref/pref		prints the `want` table of pooltest.zig
#	tools/poolref/pref -t A 1	every operation of configuration A, seed 1;
#					compare with POOLTEST_TRACE=A:1 of the Zig test
# POOLTEST_OPS and POOLTEST_SEEDS in the environment mean what they do
# for the Zig test.
S=${1:?usage: build.sh /path/to/9front/sys}
S=$(cd "$S" && pwd) || exit 1
cd "$(dirname "$0")" || exit 1
CF="-std=gnu2x -fplan9-extensions -fwrapv -fno-strict-aliasing -O1 -w -Iinclude -I$S/include"
mkdir -p obj; rm -f obj/*.o
# The only change to pool.c: a space in "0x...E+1", which ISO C reads
# as one malformed number where the Plan 9 compilers read a sum.
sed 's/\(0x[0-9A-Fa-f]*[Ee]\)+1/\1 +1/' $S/src/libc/port/pool.c >obj/pool.c || exit 1
gcc $CF -c obj/pool.c -o obj/pool.o || exit 1
gcc $CF -c main.c -o obj/main.o && gcc -O1 -w -c support.c -o obj/support.o && gcc obj/*.o -o pref
