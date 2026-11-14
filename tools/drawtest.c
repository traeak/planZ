/*
 * drawtest - draw the same scenes with 9front's libdraw as planZ's Zig
 * port does (src/user/cmd/drawtest.zig, which prints the same lines),
 * off the screen, and print what each call returned and a hash of the
 * pixels.  Not part of 9front; compiled in the guest by tools/usbzig.rc:
 *	6c -FTVw drawtest.c && 6l -o drawtest.stock drawtest.6
 *
 * Everything is drawn into images of its own, never on the screen,
 * so rio, the cursor and the screen's size do not matter.  Screen ids
 * (from the pid) and image names (with the pid) are not printed.
 *
 * usage: drawtest [tmpdir]	(default /tmp; three image files are
 * written there and removed)
 */
#include <u.h>
#include <libc.h>
#include <draw.h>

Display *d;
char *tmp = "/tmp";

/* FNV-1a */
ulong
hash(uchar *p, long n)
{
	ulong h;

	h = 2166136261UL;
	while(n-- > 0){
		h ^= *p++;
		h *= 16777619;
	}
	return h;
}

/* the image's rectangle, channels and pixels, a hash every 16 rows */
void
dump(char *label, Image *i)
{
	char cbuf[20];
	int bpl, y, dy, n;
	uchar *buf;

	bpl = bytesperline(i->r, i->depth);
	n = bpl*Dy(i->r);
	buf = malloc(n);
	if(buf == nil)
		sysfatal("malloc: %r");
	if(unloadimage(i, i->r, buf, n) != n)
		print("%s: unloadimage: %r\n", label);
	print("%s %R %s %d repl %d clipr %R:", label, i->r, chantostr(cbuf, i->chan), i->depth, i->repl, i->clipr);
	for(y = 0; y < Dy(i->r); y += 16){
		dy = Dy(i->r) - y;
		if(dy > 16)
			dy = 16;
		print(" %08lux", hash(buf+y*bpl, dy*bpl));
	}
	print("\n");
	free(buf);
}

Image*
col(ulong c)
{
	Image *i;

	i = allocimage(d, Rect(0, 0, 1, 1), RGB24, 1, c);
	if(i == nil)
		sysfatal("allocimage: %r");
	return i;
}

Image*
alloc(Rectangle r, ulong chan, int repl, ulong c)
{
	Image *i;

	i = allocimage(d, r, chan, repl, c);
	if(i == nil)
		sysfatal("allocimage %R: %r", r);
	return i;
}

/* allocimage, draw, the ops, masks, replicated and clipped sources */
void
drawing(void)
{
	Image *c, *red, *blue, *grn, *m1, *m8, *tile;
	uchar ramp[64*16];
	int x, y;

	print("display image %d white %d black %d opaque %d transparent %d new %d\n",
		d->image != nil, d->white->id, d->black->id, d->opaque == d->white, d->transparent == d->black,
		d->_isnewdisplay);
	c = alloc(Rect(0, 0, 240, 160), RGB24, 0, DWhite);
	print("canvas id %d depth %d\n", c->id, c->depth);
	red = col(DRed);
	blue = col(DBlue);
	grn = col(0x22AA44FF);
	draw(c, Rect(10, 10, 100, 60), red, nil, ZP);
	drawop(c, Rect(50, 30, 150, 90), blue, nil, ZP, SxorD);
	drawop(c, Rect(120, 20, 200, 120), grn, nil, ZP, DoverS);

	/* a GREY8 ramp as an alpha mask, and a GREY1 checkerboard */
	m8 = alloc(Rect(0, 0, 64, 16), GREY8, 0, DBlack);
	for(y = 0; y < 16; y++)
		for(x = 0; x < 64; x++)
			ramp[y*64+x] = x*4 + y;
	print("loadimage %d\n", loadimage(m8, m8->r, ramp, sizeof ramp));
	draw(c, Rect(20, 100, 84, 116), blue, m8, ZP);
	gendraw(c, Rect(90, 100, 154, 116), red, ZP, m8, Pt(8, 2));
	m1 = alloc(Rect(0, 0, 8, 8), GREY1, 1, DBlack);
	for(y = 0; y < 8; y++)
		ramp[y] = (y&1) ? 0xAA : 0x55;
	print("loadimage %d\n", loadimage(m1, Rect(0, 0, 8, 8), ramp, 8));
	draw(c, Rect(160, 100, 230, 150), grn, m1, ZP);
	gendrawop(c, Rect(5, 130, 75, 155), red, ZP, m1, Pt(3, 1), S);

	/* a tile replicated through a clip rectangle */
	tile = alloc(Rect(0, 0, 4, 4), RGB24, 1, DYellow);
	draw(tile, Rect(0, 0, 2, 2), blue, nil, ZP);
	replclipr(tile, 1, Rect(-100, -100, 100, 100));
	print("tile repl %d clipr %R\n", tile->repl, tile->clipr);
	replclipr(c, 0, Rect(100, 120, 140, 160));
	draw(c, c->r, tile, nil, ZP);
	replclipr(c, 0, c->r);

	/* errors: devdraw's, and libdraw's own */
	if(allocimage(d, Rect(10, 10, 0, 0), RGB24, 0, DWhite) == nil)
		print("bad rect: %r\n");
	if(allocimage(d, Rect(0, 0, 1, 1), 0, 0, DWhite) == nil)
		print("bad chan: %r\n");
	if(allocimage(d, Rect(0, 0, 1, 1), CHAN1(CRed, 3), 0, DWhite) == nil)
		print("bad depth: %r\n");

	flushimage(d, 0);
	dump("drawing", c);
	dump("ramp", m8);
	dump("check", m1);
	freeimage(m8);
	freeimage(m1);
	freeimage(tile);
	freeimage(c);
	freeimage(red);
	freeimage(blue);
	freeimage(grn);
}

/* loadimage and unloadimage longer than the buffer, and rows wider */
void
loading(void)
{
	Image *w;
	uchar *b, *u;
	int i, n;

	print("bufsize %d\n", d->bufsize);
	/* a row longer than the buffer: loaded and read in pieces */
	w = alloc(Rect(0, 0, 22001, 2), RGB24, 0, DBlack);
	n = bytesperline(w->r, w->depth)*Dy(w->r);
	b = malloc(n);
	u = malloc(n);
	for(i = 0; i < n; i++)
		b[i] = i*7 + (i>>8);
	print("wide load %d\n", loadimage(w, w->r, b, n));
	print("wide unload %d\n", unloadimage(w, w->r, u, n));
	print("same %d\n", memcmp(b, u, n) == 0);
	print("short load %d", loadimage(w, w->r, b, n-1));
	print(" %r\n");
	print("outside %d", loadimage(w, Rect(0, 0, 22002, 1), b, n));
	print(" %r\n");
	dump("wide", w);
	freeimage(w);
	free(b);
	free(u);

	w = alloc(Rect(-5, 7, 395, 107), XRGB32, 0, DBlack);
	n = bytesperline(w->r, w->depth)*Dy(w->r);
	b = malloc(n);
	for(i = 0; i < n; i++)
		b[i] = i ^ (i>>9);
	print("tall load %d\n", loadimage(w, w->r, b, n));
	dump("tall", w);
	freeimage(w);
	free(b);
}

/* image files: as written by hand here, in both formats, read back */
void
files(void)
{
	char path[128], cbuf[20];
	Image *i, *r;
	uchar *b;
	int fd, n, bpl;

	i = alloc(Rect(3, 4, 43, 24), CMAP8, 0, DWhite);
	bpl = bytesperline(i->r, i->depth);
	n = bpl*Dy(i->r);
	b = malloc(n);
	for(fd = 0; fd < n; fd++)
		b[fd] = fd*13;
	loadimage(i, i->r, b, n);

	snprint(path, sizeof path, "%s/drawtest.new", tmp);
	fd = create(path, OWRITE, 0666);
	if(fd < 0)
		sysfatal("create %s: %r", path);
	fprint(fd, "%11s %11d %11d %11d %11d ", chantostr(cbuf, i->chan),
		i->r.min.x, i->r.min.y, i->r.max.x, i->r.max.y);
	write(fd, b, n);
	close(fd);
	fd = open(path, OREAD);
	r = readimage(d, fd, 0);
	close(fd);
	if(r == nil)
		print("readimage new: %r\n");
	else{
		dump("new", r);
		freeimage(r);
	}

	/* the old format: ldepth 3, the bits inverted */
	snprint(path, sizeof path, "%s/drawtest.old", tmp);
	fd = create(path, OWRITE, 0666);
	fprint(fd, "%11d %11d %11d %11d %11d ", 3,
		i->r.min.x, i->r.min.y, i->r.max.x, i->r.max.y);
	for(n = 0; n < bpl*Dy(i->r); n++)
		b[n] ^= 0xFF;
	write(fd, b, n);
	close(fd);
	fd = open(path, OREAD);
	r = readimage(d, fd, 0);
	close(fd);
	if(r == nil)
		print("readimage old: %r\n");
	else{
		dump("old", r);
		freeimage(r);
	}
	remove(path);
	snprint(path, sizeof path, "%s/drawtest.new", tmp);
	remove(path);

	/* a bad header */
	snprint(path, sizeof path, "%s/drawtest.bad", tmp);
	fd = create(path, ORDWR, 0666);
	fprint(fd, "%11s %11d %11d %11d %11d ", "q9", 0, 0, 1, 1);
	seek(fd, 0, 0);
	if(readimage(d, fd, 0) == nil)
		print("readimage bad: %r\n");
	close(fd);
	remove(path);
	freeimage(i);
	free(b);
}

/* a screen on an image of its own, windows on it */
void
windows(void)
{
	Image *base, *fill, *w[4], *c;
	Screen *s;
	int i;
	ulong cols[4] = { DRed, DGreen, DBlue, DPaleyellow };

	base = alloc(Rect(0, 0, 200, 150), RGB24, 0, DBlack);
	fill = col(DPalebluegreen);
	d->screenimage = base;
	s = allocscreen(base, fill, 0);
	if(s == nil)
		sysfatal("allocscreen: %r");
	print("screen image %d fill %d\n", s->image == base, s->fill == fill);
	for(i = 0; i < 4; i++){
		w[i] = allocwindow(s, Rect(10+30*i, 10+20*i, 110+30*i, 90+20*i), Refbackup, cols[i]);
		if(w[i] == nil)
			sysfatal("allocwindow: %r");
		print("window %d %R screen %d\n", w[i]->id, w[i]->r, w[i]->screen == s);
	}
	print("windows list %d %d %d %d %d\n", d->windows == w[3], w[3]->next == w[2],
		w[2]->next == w[1], w[1]->next == w[0], w[0]->next == nil);
	c = col(DWhite);
	draw(w[1], Rect(20, 40, 200, 60), c, nil, ZP);
	print("flush visible %d\n", flushimage(d, 1));
	dump("stacked", base);
	topwindow(w[0]);
	bottomwindow(w[3]);
	dump("top0bottom3", base);
	topnwindows(w+1, 2);
	dump("topn", base);
	bottomnwindows(w, 2);
	dump("bottomn", base);
	print("origin %d", originwindow(w[2], Pt(0, 0), Pt(5, 60)));
	print(" %R %R\n", w[2]->r, w[2]->clipr);
	draw(w[2], Rect(0, 0, 30, 30), c, nil, ZP);
	dump("origin", base);
	freeimage(w[1]);
	print("windows list %d %d %d\n", d->windows == w[3], w[3]->next == w[2], w[2]->next == w[0]);
	dump("freed", base);
	for(i = 0; i < 4; i++)
		if(i != 1)
			freeimage(w[i]);
	dump("empty", base);
	print("freescreen %d\n", freescreen(s));
	d->screenimage = nil;
	freeimage(c);
	freeimage(fill);
	freeimage(base);
}

/* naming an image and looking it up by name */
void
names(void)
{
	char name[64];
	Image *i, *n;

	i = alloc(Rect(1, 2, 31, 22), GREY8, 0, 0x808080FF);
	replclipr(i, 0, Rect(5, 5, 25, 15));
	snprint(name, sizeof name, "drawtest.%d", getpid());
	print("nameimage %d\n", nameimage(i, name, 1));
	n = namedimage(d, name);
	if(n == nil)
		print("namedimage: %r\n");
	else{
		print("named %R %R %d %d\n", n->r, n->clipr, n->depth, n->repl);
		dump("named", n);
		freeimage(n);
	}
	print("unname %d\n", nameimage(i, name, 0));
	if(namedimage(d, name) == nil)
		print("gone: %r\n");
	if(namedimage(d, "") == nil)
		print("empty: %r\n");
	freeimage(i);
}

void
text(Image *c, Font *f, char *label)
{
	Image *ink, *bg;
	Point p;
	Rune r[] = { 'R', 'u', 'n', 'e', 's', ' ', 0x3B1, 0x3B2, 0x263A, 0 };
	char long1[300];
	int i;

	ink = col(DBlack);
	bg = col(DPaleyellow);
	print("%s height %d ascent %d\n", label, f->height, f->ascent);
	p = string(c, Pt(2, 2), ink, ZP, f, "Hello, world");
	print("string %P\n", p);
	p = stringn(c, Pt(2, 2+f->height), ink, ZP, f, "stringn cut here", 7);
	print("stringn %P\n", p);
	p = runestring(c, Pt(2, 2+2*f->height), ink, ZP, f, r);
	print("runestring %P\n", p);
	p = stringbg(c, Pt(2, 2+3*f->height), ink, ZP, f, "on a background", bg, ZP);
	print("stringbg %P\n", p);
	p = stringop(c, Pt(2, 2+4*f->height), ink, ZP, f, "with S", S);
	print("stringop %P\n", p);
	p = string(c, Pt(2, 2+5*f->height), ink, ZP, f, "Ünïcödé — αβγ кот ─┼─ ☺ ");
	print("unicode %P\n", p);
	print("widths %d %d %d %d\n", stringwidth(f, "Hello, world"), stringnwidth(f, "Hello", 3),
		runestringwidth(f, r), runestringnwidth(f, r, 7));
	p = stringsize(f, "size");
	print("stringsize %P\n", p);
	/* more than the cache holds, and longer than one message */
	for(i = 0; i < nelem(long1)-1; i++)
		long1[i] = 33 + (i*7)%94;
	long1[i] = 0;
	p = string(c, Pt(2, 2+6*f->height), ink, ZP, f, long1);
	print("long %P width %d\n", p, stringwidth(f, long1));
	print("cache %d subf %d width %d\n", f->ncache, f->nsubf, f->width);
	freeimage(ink);
	freeimage(bg);
}

/* the built-in font, as initdraw makes it */
void
deffont(void)
{
	char buf[128];
	Subfont *df;
	Font *f;
	Image *c;

	df = getdefont(d);
	if(df == nil)
		sysfatal("getdefont: %r");
	d->defaultsubfont = df;
	print("defont n %d height %d ascent %d bits %R\n", df->n, df->height, df->ascent, df->bits->r);
	snprint(buf, sizeof buf, "%d %d\n0 %d\t%s\n", df->height, df->ascent, df->n-1, "*default*");
	f = buildfont(d, buf, "*default*");
	if(f == nil)
		sysfatal("buildfont: %r");
	d->defaultfont = f;
	c = alloc(Rect(0, 0, 400, 140), GREY8, 0, DWhite);
	text(c, f, "default");
	dump("deftext", c);
	freeimage(c);
}

/* a font from files: several subfonts, compressed images */
void
filefont(void)
{
	Font *f;
	Image *c;
	Rune r[301];
	char fbuf[64];
	Point p;
	int i, n;

	f = openfont(d, "/lib/font/bit/vga/unicode.font");
	if(f == nil)
		sysfatal("openfont: %r");
	print("vga nsub %d\n", f->nsub);
	c = alloc(Rect(0, 0, 600, 160), RGB24, 0, DWhite);
	text(c, f, "vga");

	/* runes from many subfonts in turn: the subfont list grows */
	n = 0;
	for(i = 0; i < 60; i++){
		r[n++] = 0x41 + i%26;
		r[n++] = 0x3B1 + i%20;
		r[n++] = 0x430 + i%30;
		r[n++] = 0x2500 + i%40;
		r[n++] = 0x2190 + i%8;
	}
	r[n] = 0;
	print("mixed width %d\n", runestringwidth(f, r));
	runestring(c, Pt(0, 130), d->black, ZP, f, r);
	print("cache %d subf %d width %d\n", f->ncache, f->nsubf, f->width);
	dump("vgatext", c);

	/* the ages renormalised at 65536: old subfonts are freed */
	for(i = 0; i < 70000; i++)
		stringwidth(f, "A");
	print("aged %lud cache %d subf %d\n", f->age, f->ncache, f->nsubf);
	n = 0;
	for(i = 0; i < 20; i++){
		r[n++] = 0x5D0 + i%27;
		r[n++] = 0x391 + i%17;
		r[n++] = 0x2200 + i%30;
	}
	r[n] = 0;
	draw(c, c->r, d->white, nil, ZP);
	p = runestring(c, Pt(0, 0), d->black, ZP, f, r);
	print("after age %P %lud cache %d subf %d\n", p, f->age, f->ncache, f->nsubf);
	for(i = 0; i < f->nsubf; i++)
		print(" %lud", f->subf[i].age);
	print("\n");
	dump("agedtext", c);
	freeimage(c);
	freefont(f);

	/* a subfont taller above the baseline than its font */
	strcpy(fbuf, "16 10\n0 0x7f /lib/font/bit/vga/vga.0000-007F\n");
	f = buildfont(d, fbuf, "asc");
	if(f == nil)
		sysfatal("buildfont: %r");
	c = alloc(Rect(0, 0, 200, 20), GREY8, 0, DWhite);
	p = string(c, Pt(1, 1), d->black, ZP, f, "Ascent gjpqy|");
	print("ascent %P %d %d\n", p, f->height, f->ascent);
	dump("asctext", c);
	freeimage(c);
	freefont(f);

	if(openfont(d, "/nonexistent.font") == nil)
		print("openfont: %r\n");
	if(buildfont(d, "x y\n", "bad") == nil)
		print("buildfont: %r\n");
	if(buildfont(d, "10 8\n5 3 a\n", "bad") == nil)
		print("buildfont: %r\n");
	/* buildfont writes into its text: not a string constant */
	strcpy(fbuf, "10 8\n0x20 0x7e 0 sub\n0x100 0x17f 0x20 other\n");
	f = buildfont(d, fbuf, "/x/y.font");
	if(f == nil)
		print("buildfont: %r\n");
	else{
		print("built %d %d nsub %d", f->height, f->ascent, f->nsub);
		for(i = 0; i < f->nsub; i++)
			print(" [%ud %ud %d %s]", f->sub[i]->min, f->sub[i]->max, f->sub[i]->offset, f->sub[i]->name);
		print("\n");
		freefont(f);
	}
}

void
main(int argc, char **argv)
{
	if(argc > 1)
		tmp = argv[1];
	d = initdisplay(nil, nil, nil);
	if(d == nil)
		sysfatal("initdisplay: %r");
	drawing();
	loading();
	files();
	windows();
	names();
	deffont();
	filefont();
	print("done\n");
	exits(nil);
}
