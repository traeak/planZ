/*
 * fltest - print 9front's %e %f %g and strtod over generated values,
 * for comparison with planZ's Zig port (src/user/cmd/fltest.zig, which
 * prints the same lines).  Not part of 9front; compiled in the guest by
 * tools/usbzig.rc:  6c -FTVw fltest.c && 6l -o fltest.stock fltest.6
 *
 * Both sides make the same values with the same xorshift generator:
 * random bit patterns, exact multiples of 1/8 (halfway cases for the
 * decimal rounding), and fixed edge cases, each through the same list
 * of formats; then generated decimal strings through strtod, printing
 * the result's bits and how much of the string it used.
 */
#include <u.h>
#include <libc.h>
#include <bio.h>

Biobuf bout;
uvlong rng = 0x9e3779b97f4a7c15ULL;

uvlong
next(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return rng;
}

double
frombits(uvlong b)
{
	FPdbleword w;

	w.hi = b >> 32;
	w.lo = b;
	return w.x;
}

uvlong
tobits(double d)
{
	FPdbleword w;

	w.x = d;
	return (uvlong)w.hi << 32 | w.lo;
}

uvlong edges[] = {
	0x0000000000000000ULL, 0x8000000000000000ULL, 0x0000000000000001ULL,
	0x000fffffffffffffULL, 0x0010000000000000ULL, 0x7fefffffffffffffULL,
	0x3ff0000000000000ULL, 0xbff0000000000000ULL, 0x3fb999999999999aULL,
	0x3fe0000000000000ULL, 0x4004000000000000ULL, 0x44b52d02c7e14af6ULL,
	0x44b52d02c7e14af7ULL, 0x4340000000000001ULL, 0x7ff8000000000000ULL,
	0xfff8000000000000ULL, 0x7ff0000000000000ULL, 0xfff0000000000000ULL,
	0x3ee4f8b588e368f1ULL, 0x3f1a36e2eb1c432dULL, 0x412e847f00000000ULL,
	0x4023000000000000ULL, 0x3fee666666666666ULL, 0x3fa999999999999aULL,
	0x3fefffffffffffffULL, 0x4024000000000000ULL, 0x40c3880000000000ULL,
	0x3f50624dd2f1a9fcULL, 0x7e37e43c8800759cULL, 0x0360000000000000ULL,
	0x3feffffffffffff0ULL, 0x40fe847fffffffffULL, 0x4197d78400000000ULL,
	0x3c9cd2b297d889bcULL, 0x0000000000000400ULL, 0x00000000deadbeefULL,
	0x400921fb54442d18ULL, 0x4005bf0a8b145769ULL,
};

/*
 * Each field is formatted on its own with snprint and written: one
 * Bprint of all 17 made the stock library fault (nil read) on the line
 * for -1.04e49, for a reason not found yet (see PLAN.md).  The stock
 * _floatfmt's buffer is also one byte short for %.30f of a value at or
 * below -1e308 ('-', 309 digits, '.', 30 digits and its 0), which
 * faults too: that field is skipped on both sides.  (The Zig port's
 * buffer needs no 0, so it prints it whole.)
 */
char *fmts[] = {
	"|%g", "|%.17g", "|%e", "|%.0e", "|%f", "|%.30f", "|%#g", "|%+e", "|% f",
	"|%-12.3E", "|%.3g", "|%G", "|%10.4f", "|%.15e", "|%.1f", "|%#.0f",
};

void
show(double v)
{
	char buf[512];
	int i;

	Bprint(&bout, "%.16llux", tobits(v));
	for(i = 0; i < nelem(fmts); i++){
		/* isNaN first: 6c's code takes NaN <= -1e308 as true */
		if(i == 5 && !isNaN(v) && v <= -1e308){
			Bwrite(&bout, "|skip", 5);
			continue;
		}
		snprint(buf, sizeof buf, fmts[i], v);
		Bwrite(&bout, buf, strlen(buf));
	}
	Bputc(&bout, '\n');
}

char *fixed[] = {
	"0", "-0", "  12", "+.5", "-.5e-3", "1e", "1e+", "1e-x", ".e5", "e5", ".",
	"-", "00012.500", "0.0000", "nan", "NaN(1)", "-nan", "inf", "-Infinity",
	"infin", "1e400", "-1e400", "1e-400", "2.2250738585072011e-308",
	"2.2250738585072012e-308", "4.9406564584124654e-324", "2.4703282292062327e-324",
	"2.4703282292062328e-324", "1.7976931348623157e308", "1.7976931348623158e308",
	"1.7976931348623159e308", "9007199254740993", "9007199254740992.5",
	"123456789012345678901234567890", "0.1", "0.30000000000000004", "1e23",
	"8.98846567431158e307", "1x", "\t\n 7", "1.5E+2", "1.5e+02z", "1e2147483648",
	"1e-2147483649",
};

void
showstr(char *s)
{
	char *e;
	double v;

	v = strtod(s, &e);
	Bprint(&bout, "%.16llux %ld\n", tobits(v), (long)(e - s));
}

void
main(void)
{
	int i, j, nd, ex;
	uvlong b;
	char s[2000], *p;

	Binit(&bout, 1, OWRITE);
	for(i = 0; i < nelem(edges); i++)
		show(frombits(edges[i]));
	for(i = 0; i < 10000; i++)
		show(frombits(next()));
	for(i = 0; i < 2000; i++){
		b = next();
		show((double)(vlong)(b % 2000000) / 8.0 * ((b>>40)&1 ? -1 : 1));
	}

	for(i = 0; i < nelem(fixed); i++)
		showstr(fixed[i]);
	/* 1 followed by 1600 zeros, and a point and 1600 zeros then 1 */
	p = s;
	*p++ = '1';
	for(i = 0; i < 1600; i++)
		*p++ = '0';
	*p = 0;
	showstr(s);
	p = s;
	*p++ = '0';
	*p++ = '.';
	for(i = 0; i < 1600; i++)
		*p++ = '0';
	*p++ = '1';
	*p = 0;
	showstr(s);
	/* generated decimals: sign, 1 to 25 digits with a point somewhere, an exponent */
	for(i = 0; i < 10000; i++){
		b = next();
		p = s;
		if(b & 1)
			*p++ = '-';
		nd = 1 + (b >> 1) % 25;
		for(j = 0; j < nd; j++){
			if(j == (b >> 8) % 30)
				*p++ = '.';
			*p++ = '0' + next() % 10;
		}
		ex = (int)((b >> 16) % 700) - 350;
		p += sprint(p, "e%d", ex);
		*p = 0;
		showstr(s);
	}
	Bterm(&bout);
	exits(nil);
}
