//! rc's parser: 9front yacc's driver over the tables yacc made from
//! syn.y (syn_tab.zig), with syn.y's actions.
//! from /sys/lib/yaccpar and cmd/rc/syn.y
//!
//! DIFF:
//!   - The tables are stock yacc's own, copied (tools/yacctab.sh), so the
//!     parse, its lookahead and its errors are stock rc's.  The driver's
//!     gotos are a labeled switch; the stack holds indices.
//!   - yydebug, never on in rc, is left out.
//!   - The action of the rule `rc: line '\n'` calls compile through
//!     `compile`, code.zig's (the host tests set their own).

const std = @import("std");
const rc = @import("rc.zig");
const t = @import("syn_tab.zig");
const tree = @import("tree.zig");
const lex = @import("lex.zig");
const here = @import("here.zig");

const Tree = rc.Tree;

pub var yylval: ?*Tree = null;
pub var yyval: ?*Tree = null;
pub var yynerrs: i32 = 0; // number of errors
pub var yyerrflag: i32 = 0; // error recovery flag

/// Compile a command's tree; false if it had errors.
pub var compile: *const fn (?*Tree) bool = &@import("code.zig").compile;

fn yylex1() i32 {
    var c: i32 = undefined;
    const yychar = lex.yylex();
    if (yychar <= 0) {
        c = t.yytok1[0];
    } else if (yychar < t.yytok1.len) {
        c = t.yytok1[@intCast(yychar)];
    } else if (yychar >= t.YYPRIVATE and yychar < t.YYPRIVATE + t.yytok2.len) {
        c = t.yytok2[@intCast(yychar - t.YYPRIVATE)];
    } else {
        c = 0;
        var i: usize = 0;
        while (true) : (i += 2) {
            const v = t.yytok3[i];
            if (v == yychar) {
                c = t.yytok3[i + 1];
                break;
            }
            if (v == 0)
                break;
        }
    }
    if (c == 0)
        c = t.yytok2[1]; // unknown char
    return c;
}

const Entry = struct { yyv: ?*Tree, yys: i32 };

pub fn yyparse() i32 {
    var yys: [rc.YYMAXDEPTH]Entry = @splat(.{ .yyv = null, .yys = 0 });
    var yyp: isize = -1;
    var yystate: i32 = 0;
    var yychar: i32 = -1;
    var yyn: i32 = undefined;

    const save1 = yylval;
    const save2 = yyval;
    const save3 = yynerrs;
    const save4 = yyerrflag;

    yynerrs = 0;
    yyerrflag = 0;

    const L = enum { stack, newstate, default, ret0, ret1 };
    st: switch (L.stack) {
        .ret0, .ret1 => |r| {
            yylval = save1;
            yyval = save2;
            yynerrs = save3;
            yyerrflag = save4;
            return if (r == .ret0) 0 else 1;
        },
        .stack => {
            // put a state and value onto the stack
            yyp += 1;
            if (yyp >= rc.YYMAXDEPTH) {
                lex.yyerror("yacc stack overflow");
                continue :st .ret1;
            }
            yys[@intCast(yyp)] = .{ .yys = yystate, .yyv = yyval };
            continue :st .newstate;
        },
        .newstate => {
            yyn = t.yypact[@intCast(yystate)];
            if (yyn <= t.YYFLAG)
                continue :st .default; // simple state
            if (yychar < 0)
                yychar = yylex1();
            yyn += yychar;
            if (yyn < 0 or yyn >= t.YYLAST)
                continue :st .default;
            yyn = t.yyact[@intCast(yyn)];
            if (t.yychk[@intCast(yyn)] == yychar) { // valid shift
                yychar = -1;
                yyval = yylval;
                yystate = yyn;
                if (yyerrflag > 0)
                    yyerrflag -= 1;
                continue :st .stack;
            }
            continue :st .default;
        },
        .default => {
            // default state action
            yyn = t.yydef[@intCast(yystate)];
            if (yyn == -2) {
                if (yychar < 0)
                    yychar = yylex1();

                // look through exception table
                var xi: usize = 0;
                while (!(t.yyexca[xi] == -1 and t.yyexca[xi + 1] == yystate))
                    xi += 2;
                xi += 2;
                while (true) : (xi += 2) {
                    yyn = t.yyexca[xi];
                    if (yyn < 0 or yyn == yychar)
                        break;
                }
                yyn = t.yyexca[xi + 1];
                if (yyn < 0)
                    continue :st .ret0;
            }
            if (yyn == 0) {
                // error ... attempt to resume parsing
                if (yyerrflag == 3) {
                    // no shift yet; clobber input char
                    if (yychar == t.YYEOFCODE)
                        continue :st .ret1;
                    yychar = -1;
                    continue :st .newstate; // try again in the same state
                }
                if (yyerrflag == 0) { // brand new error
                    lex.yyerror("syntax error");
                    yynerrs += 1;
                }
                // incompletely recovered error ... try again
                yyerrflag = 3;

                // find a state where "error" is a legal shift action
                while (yyp >= 0) {
                    yyn = t.yypact[@intCast(yys[@intCast(yyp)].yys)] + t.YYERRCODE;
                    if (yyn >= 0 and yyn < t.YYLAST) {
                        yystate = t.yyact[@intCast(yyn)]; // simulate a shift of "error"
                        if (t.yychk[@intCast(yystate)] == t.YYERRCODE)
                            continue :st .stack;
                    }
                    // the current yyp has no shift onn "error", pop stack
                    yyp -= 1;
                }
                // there is no state on the stack with an error shift ... abort
                continue :st .ret1;
            }

            // reduction by production yyn
            const yypt: usize = @intCast(yyp);
            yyp -= t.yyr2[@intCast(yyn)];
            yyval = yys[@intCast(yyp + 1)].yyv;
            const yym = yyn;

            // consult goto table to find next state
            yyn = t.yyr1[@intCast(yyn)];
            const yyg = t.yypgo[@intCast(yyn)];
            const yyj = yyg + yys[@intCast(yyp)].yys + 1;

            if (yyj >= t.YYLAST or blk: {
                yystate = t.yyact[@intCast(yyj)];
                break :blk t.yychk[@intCast(yystate)] != -yyn;
            })
                yystate = t.yyact[@intCast(yyg)];

            const v = struct {
                fn at(s: []Entry, top: usize, k: usize) ?*Tree {
                    return s[top - k].yyv;
                }
            }.at;
            const s = yys[0..];
            switch (yym) {
                1 => return 1,
                2 => {
                    here.readhere(lex.lex.?.input);
                    return @intFromBool(!compile(v(s, yypt, 1)));
                },
                4, 6 => yyval = tree.tree2(';', v(s, yypt, 1), v(s, yypt, 0)),
                8 => yyval = tree.tree1('&', v(s, yypt, 1)),
                10 => here.readhere(lex.lex.?.input),
                11 => yyval = tree.tree1(rc.BRACE, v(s, yypt, 1)),
                12 => yyval = tree.tree1(rc.PCMD, v(s, yypt, 1)),
                13 => yyval = tree.tree2('=', v(s, yypt, 2), v(s, yypt, 0)),
                14, 18, 70 => yyval = null,
                15 => {
                    const r = v(s, yypt, 1).?;
                    yyval = tree.mung2(r, r.child[0], v(s, yypt, 0));
                },
                16 => {
                    const r = tree.mung1(v(s, yypt, 1).?, v(s, yypt, 0));
                    yyval = r;
                    if (r.rtype == rc.HERE)
                        here.heredoc(r);
                },
                19 => yyval = tree.epimung(v(s, yypt, 1), v(s, yypt, 0)),
                20, 22, 24, 26, 28, 30 => lex.skipnl(),
                21, 29 => yyval = tree.mung2(v(s, yypt, 3).?, v(s, yypt, 2), v(s, yypt, 0)),
                23 => yyval = tree.mung1(v(s, yypt, 2).?, v(s, yypt, 0)),
                25 => {
                    const w = v(s, yypt, 3);
                    yyval = tree.mung3(v(s, yypt, 7).?, v(s, yypt, 5), w orelse tree.tree1(rc.PAREN, w), v(s, yypt, 0));
                },
                27 => yyval = tree.mung3(v(s, yypt, 5).?, v(s, yypt, 3), null, v(s, yypt, 0)),
                31 => yyval = tree.tree2(rc.SWITCH, v(s, yypt, 2), v(s, yypt, 0)),
                32 => yyval = tree.simplemung(v(s, yypt, 0)),
                33 => yyval = tree.mung2(v(s, yypt, 2).?, v(s, yypt, 1), v(s, yypt, 0)),
                34 => yyval = tree.tree2(rc.ANDAND, v(s, yypt, 2), v(s, yypt, 0)),
                35 => yyval = tree.tree2(rc.OROR, v(s, yypt, 2), v(s, yypt, 0)),
                36 => yyval = tree.mung2(v(s, yypt, 1).?, v(s, yypt, 2), v(s, yypt, 0)),
                37 => {
                    const r = v(s, yypt, 1).?;
                    yyval = tree.mung2(r, r.child[0], v(s, yypt, 0));
                },
                38 => {
                    const r = v(s, yypt, 1).?;
                    yyval = tree.mung3(r, r.child[0], r.child[1], v(s, yypt, 0));
                },
                39, 40 => yyval = tree.mung1(v(s, yypt, 1).?, v(s, yypt, 0)),
                41 => yyval = tree.tree2(rc.FN, v(s, yypt, 1), v(s, yypt, 0)),
                42 => yyval = tree.tree1(rc.FN, v(s, yypt, 0)),
                44, 45 => yyval = tree.globprop(tree.tree2(rc.ARGLIST, v(s, yypt, 1), v(s, yypt, 0)).?),
                47, 50 => yyval = tree.globprop(tree.tree2('^', v(s, yypt, 2), v(s, yypt, 0)).?),
                48 => {
                    lex.lex.?.lastword = true;
                    v(s, yypt, 0).?.type = rc.WORD;
                },
                51 => yyval = tree.tree1('$', v(s, yypt, 0)),
                52 => yyval = tree.tree2(rc.SUB, v(s, yypt, 3), v(s, yypt, 1)),
                53 => yyval = tree.tree1('"', v(s, yypt, 0)),
                54 => yyval = tree.tree1(rc.COUNT, v(s, yypt, 0)),
                56 => yyval = tree.tree2('`', null, v(s, yypt, 0)),
                57 => yyval = tree.tree2('`', v(s, yypt, 1), v(s, yypt, 0)),
                58 => yyval = tree.globprop(tree.tree1(rc.PAREN, v(s, yypt, 1)).?),
                59 => {
                    const r = tree.mung1(v(s, yypt, 1).?, v(s, yypt, 0));
                    r.type = rc.PIPEFD;
                    yyval = r;
                },
                71 => yyval = tree.tree2(rc.WORDS, v(s, yypt, 1), v(s, yypt, 0)),
                else => {},
            }
            continue :st .stack; // stack new state and value
        },
    }
}
