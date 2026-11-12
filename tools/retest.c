/*
 * retest - run 9front's libregexp over a table and print every result,
 * for comparison with planZ's Zig port (src/user/cmd/retest.zig, which
 * prints the same lines).  Not part of 9front; compiled in the guest by
 * tools/usbzig.rc:  6c -FTVw retest.c && 6l -o retest.stock retest.6
 *
 * Each line of the table is  flags<TAB>pattern<TAB>subject  where flags
 * is - (regcomp), n (regcompnl) or l (regcomplit), and the pattern and
 * subject may use \n, \t, \\ and \xHH.  Lines starting with # are
 * skipped.  For each line it prints the compile error, or every match
 * of a left-to-right scan with its subexpressions and a regsub of
 * TEMPLATE, then a match bounded to the first half of the subject,
 * then the same for rregexec and rregsub on the subject as runes.
 */
#include <u.h>
#include <libc.h>
#include <bio.h>
#include <regexp.h>

enum { NSUB = 10, NSCAN = 20 };
#define TEMPLATE "<&|\\1|\\2>"

char errmsg[256];

void
regerror(char *s)
{
	strecpy(errmsg, errmsg+sizeof errmsg, s);
}

int
hexval(int c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return 0;
}

/* \n \t \\ \xHH; returns the length */
int
unescape(char *s)
{
	char *r, *w;
	int c;

	for(r = w = s; *r; r++){
		if(*r != '\\' || r[1] == 0){
			*w++ = *r;
			continue;
		}
		r++;
		switch(*r){
		case 'n': *w++ = '\n'; break;
		case 't': *w++ = '\t'; break;
		case 'x':
			c = 0;
			if(r[1] && r[2]){
				c = hexval(r[1])*16 + hexval(r[2]);
				r += 2;
			}
			*w++ = c;
			break;
		default: *w++ = *r; break;
		}
	}
	*w = 0;
	return w - s;
}

void
prsubs(Resub *m, char *str)
{
	int i;

	for(i = 1; i < NSUB; i++){
		if(m[i].sp == nil && m[i].ep == nil)
			continue;
		print(" %d:", i);
		if(m[i].sp) print("%lld", (vlong)(m[i].sp - str)); else print("-");
		print("-");
		if(m[i].ep) print("%lld", (vlong)(m[i].ep - str)); else print("-");
	}
}

void
rprsubs(Resub *m, Rune *str)
{
	int i;

	for(i = 1; i < NSUB; i++){
		if(m[i].rsp == nil && m[i].rep == nil)
			continue;
		print(" %d:", i);
		if(m[i].rsp) print("%lld", (vlong)(m[i].rsp - str)); else print("-");
		print("-");
		if(m[i].rep) print("%lld", (vlong)(m[i].rep - str)); else print("-");
	}
}

void
bytes(int ln, Reprog *p, char *str, int len)
{
	Resub m[NSUB];
	char out[24];
	int n, sp, ep, any;
	Rune r;

	any = 0;
	sp = 0;
	for(n = 0; n < NSCAN && sp <= len; n++){
		memset(m, 0, sizeof m);
		m[0].sp = str + sp;
		if(!regexec(p, str, m, NSUB))
			break;
		any = 1;
		print("%d match %lld %lld", ln, (vlong)(m[0].sp - str), (vlong)(m[0].ep - str));
		prsubs(m, str);
		regsub(TEMPLATE, out, sizeof out, m, NSUB);
		print(" [%s]\n", out);
		ep = m[0].ep - str;
		if(ep > m[0].sp - str)
			sp = ep;
		else if(ep < len)
			sp = ep + chartorune(&r, str + ep);
		else
			break;
	}
	if(!any)
		print("%d none\n", ln);

	memset(m, 0, sizeof m);
	m[0].sp = str;
	m[0].ep = str + len/2;
	if(regexec(p, str, m, NSUB))
		print("%d half %lld %lld\n", ln, (vlong)(m[0].sp - str), (vlong)(m[0].ep - str));
	else
		print("%d half none\n", ln);
}

void
runes(int ln, Reprog *p, char *s)
{
	Resub m[NSUB];
	Rune str[1024], out[24];
	int n, sp, ep, any, len;

	len = 0;
	while(*s && len < nelem(str)-1)
		s += chartorune(&str[len++], s);
	str[len] = 0;

	any = 0;
	sp = 0;
	for(n = 0; n < NSCAN && sp <= len; n++){
		memset(m, 0, sizeof m);
		m[0].rsp = str + sp;
		if(!rregexec(p, str, m, NSUB))
			break;
		any = 1;
		print("%d rmatch %lld %lld", ln, (vlong)(m[0].rsp - str), (vlong)(m[0].rep - str));
		rprsubs(m, str);
		rregsub(L"<&|\\1|\\2>", out, nelem(out), m, NSUB);
		print(" [%S]\n", out);
		ep = m[0].rep - str;
		if(ep > m[0].rsp - str)
			sp = ep;
		else if(ep < len)
			sp = ep + 1;
		else
			break;
	}
	if(!any)
		print("%d rnone\n", ln);
}

void
main(int argc, char **argv)
{
	Biobuf *b;
	char *line, *f[3];
	Reprog *p;
	int ln, len;

	if(argc != 2){
		fprint(2, "usage: retest table\n");
		exits("usage");
	}
	b = Bopen(argv[1], OREAD);
	if(b == nil)
		sysfatal("open %s: %r", argv[1]);
	for(ln = 1; (line = Brdline(b, '\n')) != nil; ln++){
		line[Blinelen(b)-1] = 0;
		if(line[0] == '#' || line[0] == 0)
			continue;
		if(getfields(line, f, 3, 0, "\t") != 3){
			print("%d bad line\n", ln);
			continue;
		}
		unescape(f[1]);
		len = unescape(f[2]);
		errmsg[0] = 0;
		switch(f[0][0]){
		case 'n': p = regcompnl(f[1]); break;
		case 'l': p = regcomplit(f[1]); break;
		default: p = regcomp(f[1]); break;
		}
		if(p == nil){
			print("%d error %s\n", ln, errmsg);
			continue;
		}
		/*
		 * regcomp mallocs the program and never sets the
		 * instructions' generations, and regexec clears them only
		 * if the first one is not 0: with stale memory the first
		 * match can skip instructions.  One throwaway match sets
		 * the first, so the next clears them all.  The Zig port
		 * zeroes them (Fixed from C); it does the same call.
		 */
		regexec(p, "", nil, 0);
		bytes(ln, p, f[2], strlen(f[2]) < len ? strlen(f[2]) : len);
		runes(ln, p, f[2]);
		free(p);
	}
	exits(nil);
}
