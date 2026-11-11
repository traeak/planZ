#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>
#include <memlayer.h>

extern int printf(const char*, ...);
#define N(s) (sprintf(name, "%s.%s", cn, s), name)

static int maskx;

static uvlong
hash(Memimage *i)
{
	uvlong h;
	int n, k;
	uchar *buf;

	n = bytesperline(i->r, i->depth)*Dy(i->r);
	buf = malloc(n+1);
	k = memunload(i, i->r, buf, n);
	if(k != n)
		printf("hash: unload %d != %d\n", k, n);
	h = 0xcbf29ce484222325ULL;
	for(k = 0; k < n; k++){
		if(maskx && i->chan == XRGB32 && (k&3) == 3)
			buf[k] = 0;
		h ^= buf[k];
		h *= 0x100000001b3ULL;
	}
	free(buf);
	return h;
}

static void
out(char *name, Memimage *i)
{
	printf("%s %016llx\n", name, hash(i));
}

static Memimage*
mk(Rectangle r, ulong chan, ulong color)
{
	Memimage *i;

	i = allocmemimage(r, chan);
	memfillcolor(i, color);
	return i;
}

static Memimage*
col(ulong color)
{
	Memimage *i;

	i = mk(Rect(0,0,1,1), RGBA32, color);
	i->flags |= Frepl;
	i->clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
	return i;
}

/* a deterministic texture */
static Memimage*
tex(Rectangle r, ulong chan)
{
	Memimage *i, *c;
	int x, y;

	i = mk(r, chan, DBlack);
	for(y = r.min.y; y < r.max.y; y++)
	for(x = r.min.x; x < r.max.x; x++){
		c = col(((ulong)(x*37+y*11)&0xFF)<<24 | ((ulong)(x*5+y*23)&0xFF)<<16 | ((ulong)(x*x+y)&0xFF)<<8 | 0xFF);
		memimagedraw(i, Rect(x,y,x+1,y+1), c, ZP, nil, ZP, S);
		freememimage(c);
	}
	return i;
}

static int nrefresh;
static int refresharea;
static Memimage *refcol;

static void
refresh(Memimage *dst, Rectangle r, void *v)
{
	nrefresh++;
	refresharea += Dx(r)*Dy(r);
	USED(v);
	memdraw(dst, r, refcol, r.min, nil, ZP, S);
}

static void
shapes(ulong chan, char *cn)
{
	Memimage *d, *red, *green, *blue, *t;
	Rectangle r;
	Point pts[8];
	char name[64];
	extern int sprintf(char*, const char*, ...);

	r = Rect(0, 0, 64, 48);
	red = col(DRed);
	green = col(0x00FF0080);	/* premultiplied half green */
	blue = col(DBlue);
	t = tex(Rect(-8, -8, 72, 56), RGB24);

	d = mk(r, chan, DWhite);
	memimageline(d, Pt(5,10), Pt(40,10), Endsquare, Endsquare, 0, red, ZP, SoverD);
	out(N("line_h"), d);
	memimageline(d, Pt(20,5), Pt(20,40), Enddisc, Endsquare, 3, blue, ZP, SoverD);
	out(N("line_v_thick"), d);
	memimageline(d, Pt(5,5), Pt(50,40), Endsquare, Endsquare, 0, green, ZP, SoverD);
	out(N("line_diag"), d);
	memimageline(d, Pt(50,5), Pt(8,30), Enddisc, Enddisc, 4, t, Pt(3,4), SoverD);
	out(N("line_diag_disc"), d);
	freememimage(d);

	d = mk(r, chan, DBlack);
	memimageline(d, Pt(10,40), Pt(55,12), Endsquare, Endarrow, 1, red, ZP, SoverD);
	out(N("line_arrow"), d);
	memimageline(d, Pt(10,20), Pt(50,20), Endarrow, ARROW(12,14,5), 2, blue, ZP, SoverD);
	out(N("line_arrow_h"), d);
	memimageline(d, Pt(30,2), Pt(30,45), ARROW(9,9,4), Endarrow, 0, green, ZP, SoverD);
	out(N("line_arrow_v"), d);
	d->clipr = Rect(10,10,30,30);
	memimageline(d, Pt(0,0), Pt(60,45), Enddisc, Enddisc, 2, t, ZP, S);
	memimageline(d, Pt(-20,25), Pt(90,26), Endsquare, Endsquare, 1, red, ZP, S);
	d->clipr = d->r;
	out(N("line_clip"), d);
	freememimage(d);

	d = mk(r, chan, DWhite);
	memellipse(d, Pt(32,24), 20, 12, 0, red, ZP, SoverD);
	out(N("ellipse_thin"), d);
	memellipse(d, Pt(32,24), 26, 18, 3, t, Pt(1,2), SoverD);
	out(N("ellipse_thick"), d);
	memellipse(d, Pt(20,20), 9, 13, -1, green, ZP, SoverD);
	out(N("ellipse_fill"), d);
	memellipse(d, Pt(40,30), 10, 10, 1, blue, ZP, SoverD);
	out(N("circle"), d);
	freememimage(d);

	d = mk(r, chan, DWhite);
	memellipse(d, Pt(32,24), 25, 3, 6, blue, ZP, SoverD);
	out(N("ellipse_brush"), d);
	memellipse(d, Pt(32,24), 2, 18, 5, red, ZP, SoverD);
	out(N("ellipse_brush2"), d);
	memellipse(d, Pt(60,44), 14, 9, 2, green, ZP, SoverD);
	out(N("ellipse_edge"), d);
	freememimage(d);

	d = mk(r, chan, DBlack);
	memarc(d, Pt(32,24), 20, 15, 2, red, ZP, 30, 100, SoverD);
	out(N("arc"), d);
	memarc(d, Pt(32,24), 12, 10, -1, t, ZP, 200, -250, SoverD);
	out(N("arc_fill"), d);
	memarc(d, Pt(32,24), 28, 22, 0, blue, ZP, -45, 350, SoverD);
	out(N("arc_big"), d);
	memarc(d, Pt(10,10), 8, 8, 1, green, ZP, 0, 360, SoverD);
	out(N("arc_full"), d);
	freememimage(d);

	d = mk(r, chan, DWhite);
	pts[0] = Pt(5,5); pts[1] = Pt(55,10); pts[2] = Pt(20,40);
	memfillpoly(d, pts, 3, ~0, red, ZP, SoverD);
	out(N("poly_tri"), d);
	pts[0] = Pt(32,2); pts[1] = Pt(44,44); pts[2] = Pt(4,16); pts[3] = Pt(60,16); pts[4] = Pt(20,44);
	memfillpoly(d, pts, 5, 1, blue, ZP, SoverD);
	out(N("poly_star_odd"), d);
	memfillpoly(d, pts, 5, ~0, green, ZP, SoverD);
	out(N("poly_star_nz"), d);
	pts[0] = Pt(-10,20); pts[1] = Pt(30,-10); pts[2] = Pt(80,30); pts[3] = Pt(30,60);
	memfillpoly(d, pts, 4, ~0, t, Pt(7,9), SoverD);
	out(N("poly_tex_clip"), d);
	freememimage(d);

	d = mk(r, chan, DBlack);
	pts[0] = Pt(5,40); pts[1] = Pt(15,8); pts[2] = Pt(40,35); pts[3] = Pt(58,6);
	mempoly(d, pts, 4, Enddisc, Endarrow, 2, red, ZP, SoverD);
	out(N("mempoly"), d);
	mempoly(d, pts, 4, Endsquare, Endsquare, 0, t, pts[0], SoverD);
	out(N("mempoly_thin"), d);
	freememimage(d);

	freememimage(red);
	freememimage(green);
	freememimage(blue);
	freememimage(t);
}

static void
layers(ulong chan, char *cn)
{
	Memscreen scr;
	Memimage *si, *fill, *a, *b, *c, *red, *green, *blue, *t, *lp[3];
	uchar buf[4096];
	Point pts[5];
	int n, i;
	char name[64];
	extern int sprintf(char*, const char*, ...);

	red = col(DRed);
	green = col(0x00FF0080);
	blue = col(DBlue);
	refcol = col(DYellow);
	t = tex(Rect(0, 0, 80, 60), RGB24);
	fill = col(0x777777FF);
	si = mk(Rect(0,0,80,60), chan, 0x777777FF);
	scr.frontmost = nil;
	scr.rearmost = nil;
	scr.image = si;
	scr.fill = fill;
	nrefresh = 0;
	refresharea = 0;

	a = memlalloc(&scr, Rect(10,10,50,40), nil, nil, DWhite);
	out(N("alloc_a"), si);
	b = memlalloc(&scr, Rect(30,20,70,55), refresh, nil, DPaleyellow);
	out(N("alloc_b"), si);
	printf("%s %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, nrefresh, refresharea);

	/* draw in a, which is partly hidden by b */
	memdraw(a, Rect(12,12,48,38), t, Pt(3,3), nil, ZP, SoverD);
	memline(a, Pt(10,10), Pt(49,39), Enddisc, Endarrow, 2, red, ZP, SoverD);
	memellipse(a, Pt(40,30), 12, 8, 2, blue, ZP, SoverD);
	out(N("draw_a.scr"), si);
	out(N("draw_a.a"), a);
	/* a line across both, and a poly in b */
	memline(b, Pt(25,25), Pt(69,50), Endsquare, Endsquare, 1, green, ZP, SoverD);
	pts[0] = Pt(35,22); pts[1] = Pt(68,30); pts[2] = Pt(40,52);
	memfillpoly(b, pts, 3, ~0, blue, ZP, SoverD);
	out(N("draw_b.scr"), si);

	memltofront(a);
	out(N("tofront_a.scr"), si);
	out(N("tofront_a.a"), a);
	printf("%s %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, nrefresh, refresharea);
	memarc(b, Pt(50,38), 15, 12, 3, red, ZP, 10, 250, SoverD);
	out(N("arc_b.scr"), si);
	memltorear(a);
	out(N("torear_a.scr"), si);
	printf("%s %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, nrefresh, refresharea);

	/* a third window hanging off the screen */
	c = memlalloc(&scr, Rect(60,35,100,80), nil, nil, DGreen);
	out(N("alloc_c.scr"), si);
	out(N("alloc_c.c"), c);
	memellipse(c, Pt(80,58), 18, 20, -1, red, ZP, SoverD);
	memline(c, Pt(60,35), Pt(99,79), Enddisc, Enddisc, 3, blue, ZP, SoverD);
	out(N("draw_c.scr"), si);
	out(N("draw_c.c"), c);
	printf("%s %d %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, c->layer->clear, nrefresh, refresharea);

	/* scroll within a (same layer, obscured) */
	memdraw(a, Rect(10,10,45,35), a, Pt(15,14), nil, ZP, S);
	out(N("scroll_a.scr"), si);
	out(N("scroll_a.a"), a);
	/* obscured layer as source */
	memdraw(c, Rect(62,37,98,70), a, Pt(12,12), nil, ZP, SoverD);
	out(N("a_to_c.scr"), si);
	out(N("a_to_c.c"), c);
	/* copy within c, partly off screen */
	memdraw(c, Rect(70,50,100,80), c, Pt(60,35), nil, ZP, S);
	out(N("scroll_c.c"), c);

	/* load and unload */
	for(i = 0; i < sizeof buf; i++)
		buf[i] = i*7 + (i>>5);
	n = memload(a, Rect(20,15,45,30), buf, sizeof buf, 0);
	printf("%s %d\n", N("memload"), n);
	out(N("load_a.scr"), si);
	out(N("load_a.a"), a);
	n = memload(c, Rect(65,40,95,75), buf, sizeof buf, 0);
	printf("%s %d\n", N("memload_c"), n);
	out(N("load_c.c"), c);
	n = memunload(b, Rect(30,20,70,55), buf, sizeof buf);
	printf("%s %d\n", N("memunload_b"), n);

	/* shuffles */
	lp[0] = a; lp[1] = c;
	memltofrontn(lp, 2);
	out(N("tofrontn.scr"), si);
	printf("%s %d %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, c->layer->clear, nrefresh, refresharea);
	lp[0] = c; lp[1] = a; lp[2] = b;
	memltorearn(lp, 3);
	out(N("torearn.scr"), si);
	printf("%s %d %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, c->layer->clear, nrefresh, refresharea);
	printf("%s %d %d %d\n", N("order"), scr.frontmost==a, scr.rearmost==c, a->layer->rear==b);

	/* origin: move a, then change its coordinates, then both */
	n = memlorigin(a, a->r.min, Pt(5,25));
	printf("%s %d\n", N("origin1"), n);
	out(N("origin1.scr"), si);
	out(N("origin1.a"), a);
	n = memlorigin(a, Pt(-100,-200), Pt(5,25));
	printf("%s %d %d %d\n", N("origin2"), n, a->r.min.x, a->layer->delta.y);
	out(N("origin2.scr"), si);
	out(N("origin2.a"), a);
	memline(a, Pt(-100,-200), Pt(-61,-171), Endsquare, Endsquare, 0, red, ZP, SoverD);
	n = memlorigin(c, Pt(0,0), Pt(-10,-10));
	printf("%s %d\n", N("origin3"), n);
	out(N("origin3.scr"), si);
	out(N("origin3.c"), c);
	n = memlorigin(b, Pt(3,3), Pt(45,-5));
	printf("%s %d\n", N("origin4"), n);
	out(N("origin4.scr"), si);
	n = memlorigin(b, Pt(3,3), Pt(45,-5));
	printf("%s %d\n", N("origin5"), n);
	printf("%s %d %d %d %d %d\n", N("clear"), a->layer->clear, b->layer->clear, c->layer->clear, nrefresh, refresharea);

	/* refresh method changes */
	n = memlsetrefresh(b, nil, nil);	/* refresh fn -> backup */
	printf("%s %d %d %d\n", N("setrefresh1"), n, b->layer->save!=nil, nrefresh);
	memltofront(a);
	memltofront(b);
	out(N("setrefresh1.scr"), si);
	n = memlsetrefresh(a, refresh, nil);	/* backup -> refresh fn */
	printf("%s %d %d\n", N("setrefresh2"), n, a->layer->save!=nil);
	n = memlsetrefresh(a, memlnorefresh, nil);
	printf("%s %d\n", N("setrefresh3"), n);
	memltofront(a);
	out(N("setrefresh3.scr"), si);

	memldelete(b);
	out(N("delete_b.scr"), si);
	memldelete(a);
	out(N("delete_a.scr"), si);
	printf("%s %d %d\n", N("order"), scr.frontmost==c, scr.rearmost==c);
	memlfree(c);
	out(N("free_c.scr"), si);

	freememimage(si);
	freememimage(fill);
	freememimage(red);
	freememimage(green);
	freememimage(blue);
	freememimage(refcol);
	freememimage(t);
}

static void
warps(ulong dchan, ulong schan, char *cn)
{
	Memimage *d, *s;
	Warp w;
	char name[64];
	extern int sprintf(char*, const char*, ...);

	s = tex(Rect(0,0,16,12), schan);
	d = mk(Rect(0,0,64,48), dchan, DWhite);

	/* scale by 1/3 (source step) with a little shear and an offset */
	memset(&w, 0, sizeof w);
	w.m[0][0] = 2731; w.m[0][1] = 300; w.m[0][2] = -4096;
	w.m[1][0] = -200; w.m[1][1] = 2731; w.m[1][2] = 8192;
	w.m[2][2] = 8192;
	memaffinewarp(d, Pt(2,3), Rect(2,3,60,44), s, ZP, nil, ZP, &w, 0, S);
	out(N("warp_nearest"), d);
	memaffinewarp(d, Pt(2,3), Rect(2,3,60,44), s, ZP, nil, ZP, &w, 1, SoverD);
	out(N("warp_smooth"), d);

	/* integer upscale by 4 */
	memset(&w, 0, sizeof w);
	w.m[0][0] = 2048; w.m[1][1] = 2048; w.m[2][2] = 8192;
	w.flags = WFintupscale;
	memfillcolor(d, DBlack);
	memaffinewarp(d, Pt(0,0), d->r, s, ZP, nil, ZP, &w, 0, S);
	out(N("warp_upscale"), d);
	s->flags |= Frepl;
	s->clipr = Rect(-1000,-1000,1000,1000);
	memaffinewarp(d, Pt(5,5), Rect(1,1,63,47), s, Pt(3,2), nil, ZP, &w, 0, SoverD);
	out(N("warp_upscale_repl"), d);
	{
		static double k[9] = {1,2,1, 2,4,2, 1,2,-1};
		Memimage *ik;

		ik = allocmemimagekernel(k, 3, 3, 0);
		memimagecorrelate(d, Rect(4,4,60,40), s, Pt(-2,-1), ik);
		out(N("warp_correlate"), d);
		freememimage(ik);
		ik = allocmemimagekernel(k, 3, 3, 7.5);
		memimagecorrelate(d, Rect(0,0,30,48), s, Pt(5,5), ik);
		out(N("warp_correlate2"), d);
		freememimage(ik);
	}

	freememimage(s);
	freememimage(d);
}

static void
lwarp(void)
{
	Memscreen scr;
	Memimage *si, *a, *b, *s;
	Warp w;

	s = tex(Rect(0,0,16,12), RGBA32);
	si = mk(Rect(0,0,80,60), XRGB32, 0x777777FF);
	scr.frontmost = nil;
	scr.rearmost = nil;
	scr.image = si;
	scr.fill = nil;
	a = memlalloc(&scr, Rect(10,10,50,40), nil, nil, DWhite);
	b = memlalloc(&scr, Rect(30,20,70,55), nil, nil, DPaleyellow);
	memset(&w, 0, sizeof w);
	w.m[0][0] = 3000; w.m[0][1] = -500; w.m[0][2] = 0;
	w.m[1][0] = 400; w.m[1][1] = 2500; w.m[1][2] = 0;
	w.m[2][2] = 8192;
	memlaffinewarp(a, Pt(12,12), Rect(12,12,48,38), s, ZP, nil, ZP, &w, 1, S);
	out("lwarp.scr", si);
	out("lwarp.a", a);
	memlaffinewarp(b, Pt(30,20), b->r, a, Pt(10,10), nil, ZP, &w, 0, S);
	out("lwarp2.scr", si);
	memldelete(a);
	memldelete(b);
	freememimage(si);
	freememimage(s);
}

static void
strings(ulong chan, char *cn)
{
	Memimage *d, *red;
	Memsubfont *f;
	Point p, q;
	char name[64];
	extern int sprintf(char*, const char*, ...);

	f = getmemdefont();
	red = col(DRed);
	d = mk(Rect(0,0,160,40), chan, DWhite);
	p = memimagestring(d, Pt(3,5), red, ZP, f, "Hello, Plan 9!");
	q = memsubfontwidth(f, "Hello, Plan 9!");
	printf("%s %d %d %d %d\n", N("string"), p.x, p.y, q.x, q.y);
	out(N("string.d"), d);
	p = memimagestring(d, Pt(-4,22), d, Pt(1,1), f, "{clip} ~\x7f\x01 end of line, far too long to fit");
	printf("%s %d %d\n", N("string2"), p.x, p.y);
	out(N("string2.d"), d);
	freememimage(d);
	freememimage(red);
}

void
main(int argc, char **argv)
{
	maskx = argc > 1;
	memimageinit();
	shapes(XRGB32, "x8r8g8b8");
	shapes(RGB16, "r5g6b5");
	shapes(GREY8, "k8");
	shapes(GREY1, "k1");
	shapes(CMAP8, "m8");
	shapes(RGBA32, "r8g8b8a8");
	layers(XRGB32, "x8r8g8b8");
	layers(RGB16, "r5g6b5");
	layers(GREY2, "k2");
	warps(XRGB32, RGB24, "x-rgb24");
	warps(RGB16, RGBA32, "r5g6b5-rgba");
	warps(GREY8, CMAP8, "k8-m8");
	warps(GREY2, GREY4, "k2-k4");
	warps(RGBA32, RGB15, "rgba-rgb15");
	warps(ABGR32, ARGB32, "abgr-argb");
	warps(BGR24, XBGR32, "bgr24-xbgr");
	warps(CHAN2(CAlpha, 8, CGrey, 8), CHAN2(CGrey, 8, CAlpha, 8), "a8k8-k8a8");
	lwarp();
	strings(XRGB32, "x8r8g8b8");
	strings(GREY1, "k1");
	strings(RGB16, "r5g6b5");
	extern void exit(int);
	exit(0);
}
