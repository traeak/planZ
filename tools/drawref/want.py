# Put the C reference program's output into the Zig test files, replacing
# either the "// @WANT pattern@" placeholder or an earlier `const want`.
import re, sys
ref = open(sys.argv[1]).read().splitlines()
root = sys.argv[2]
shapes, rest = ref[:150], ref[150:]
layers, warps = rest[:165], rest[165:]
files = {
 'libmemdraw/line.zig': [l for l in shapes if re.search(r'\.line_', l)],
 'libmemdraw/ellipse.zig': [l for l in shapes if re.search(r'\.(ellipse_|circle)', l)],
 'libmemdraw/arc.zig': [l for l in shapes if re.search(r'\.arc', l)],
 'libmemdraw/fillpoly.zig': [l for l in shapes if re.search(r'\.poly_', l)],
 'libmemdraw/poly.zig': [l for l in shapes if re.search(r'\.mempoly', l)],
 'libmemlayer/lalloc.zig': layers,
 'libmemdraw/warp.zig': [l for l in warps if '.warp_' in l],
 'libmemlayer/warp.zig': [l for l in warps if l.startswith('lwarp')],
 'libmemdraw/string.zig': [l for l in warps if '.string' in l],
}
assert sum(len(v) for v in files.values()) == len(ref), (sum(len(v) for v in files.values()), len(ref))
for f, lines in files.items():
    p = root + '/' + f
    s = open(p).read()
    i = s.find('// @WANT')
    if i < 0:
        i = s.index('/// What the C program printed')
    text = '/// What the C program printed (see `testing` in libmemdraw/line.zig).\nconst want =\n' + ''.join('    \\\\' + l + '\n' for l in lines) + ';\n'
    open(p, 'w').write(s[:i] + text)
