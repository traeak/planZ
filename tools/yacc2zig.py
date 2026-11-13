#!/usr/bin/env python3
"""yacc2zig - turn the tables of a 9front yacc's y.tab.c into Zig.

usage: yacc2zig.py y.tab.c y.tab.h source-name out.zig

9front's yacc writes its parser as tables (yyexca, yyact, yypact, yypgo,
yyr1, yyr2, yychk, yydef, yytok1-3) and token numbers (y.tab.h), driven
by /sys/lib/yaccpar.  This copies the tables and the numbers, unchanged,
into a Zig file; the driver and the grammar's actions are ported by hand
beside it (see src/user/cmd/rc/syn.zig).  tools/yacctab.sh runs the
stock yacc in a 9front guest and then this.
"""
import hashlib
import re
import sys

ctab, htab, source, out = sys.argv[1:5]
c = open(ctab, encoding="latin-1").read()
h = open(htab, encoding="latin-1").read()

arrays = {}
for typ, name, body in re.findall(r"\b(short|long)\s+(\w+)\[\]\s*=\s*\{([^}]*)\}", c):
    arrays[name] = (typ, [int(x) for x in re.findall(r"-?\d+", body)])
need = ["yyexca", "yyact", "yypact", "yypgo", "yyr1", "yyr2", "yychk", "yydef", "yytok1", "yytok2", "yytok3"]
for n in need:
    if n not in arrays:
        sys.exit("yacc2zig: no %s in %s" % (n, ctab))

defs = {}
for name, val in re.findall(r"^#define\s+(YY\w+)\s+(-?\d+)\s*$", c, re.M):
    defs.setdefault(name, int(val))
for n in ["YYEOFCODE", "YYERRCODE", "YYNPROD", "YYPRIVATE", "YYLAST", "YYFLAG"]:
    if n not in defs:
        sys.exit("yacc2zig: no %s in %s" % (n, ctab))
tokens = re.findall(r"^#define\s+([A-Za-z_]\w*)\s+(\d+)\s*$", h, re.M)

o = []
o.append("//! Parser tables for %s, made by 9front's yacc and copied unchanged" % source)
o.append("//! by tools/yacc2zig.py (regenerate with tools/yacctab.sh).")
o.append("//! y.tab.c SHA-1 %s, y.tab.h SHA-1 %s." % (
    hashlib.sha1(open(ctab, "rb").read()).hexdigest(),
    hashlib.sha1(open(htab, "rb").read()).hexdigest()))
o.append("")
o.append("// tokens (y.tab.h)")
for name, val in tokens:
    o.append("pub const %s = %s;" % (name, val))
o.append("")
for n in ["YYEOFCODE", "YYERRCODE", "YYNPROD", "YYPRIVATE", "YYLAST", "YYFLAG"]:
    o.append("pub const %s = %d;" % (n, defs[n]))
o.append("")
for n in need:
    typ, vals = arrays[n]
    zt = "i16" if typ == "short" else "i32"
    o.append("pub const %s = [_]%s{" % (n, zt))
    for i in range(0, len(vals), 10):
        o.append("    " + " ".join("%d," % v for v in vals[i:i + 10]))
    o.append("};")
    o.append("")
open(out, "w").write("\n".join(o).rstrip() + "\n")
