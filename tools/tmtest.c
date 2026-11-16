/*
 * tmtest - print 9front's dates: tmtime, the τ formats, tmnorm,
 * tmparse and ctime over fixed and generated times in the zones given,
 * for comparison with planZ's Zig port (src/user/cmd/tmtest.zig, which
 * prints the same lines).  Not part of 9front; compiled in the guest by
 * tools/usbzig.rc:  6c -FTVw tmtest.c && 6l -o tmtest.stock tmtest.6
 *
 * usage: tmtest zone...	(a zone file's name, local, or nil)
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

vlong tms[] = {
	0LL, -1LL, 1LL, 86399LL, 86400LL, -86400LL, -86401LL,
	951782400LL, 951868800LL, 1078012800LL, 1078099200LL,
	946684799LL, 946684800LL, 978307200LL, 4107542400LL,
	2147483647LL, 2147483648LL, -2147483648LL, -2147483649LL,
	1741514400LL, 1741539600LL, 1741539601LL, 1762070400LL, 1762095600LL, 1762095601LL,
	1743865200LL, 1743868800LL, 1759593600LL,
	1763259907LL, 4102444800LL, 32503680000LL, 253402300799LL,
	-2208988800LL, -11644473600LL, -62135596800LL, -62135596801LL, -62167219200LL, -62198755200LL,
};

char *fmts[] = {
	nil,
	"Y YY YYYY",
	"M MM MMM MMMM",
	"D DD Do",
	"W WW WWW",
	"h hh H HH m mm s ss a A",
	"t tt ttt u uu uuu uuuu",
	"n nn nnn nnnn nnnnn nnnnnn",
	"z Z ZZ ZZZ",
	"__D|__s|___MMM|__YY|____Z|_____ZZ|______ZZZ|__W|___a",
	"_t|__tt|____ttt|_u|___uu|____uuu|_______uuuu|__________nnnnnn",
	"[at] hh [o'clock] [[x\\]] [a[b]c]",
	"YYYY-MM-DDThh:mm:ssZZ",
	"?W ?M ?D",
	"x,y.z; é 1234567890",
	"YYY",
	"ab MMMMM cd",
	"DDD",
	"zz",
	"ZZZZ|",
	"WWWW",
	"hhh",
	"oo",
	"[unclosed",
	"aa",
};

typedef struct Parse Parse;
struct Parse {
	char *fmt;
	char *str;
};

Parse parses[] = {
	{"YYYY-MM-DD hh:mm:ss", "2025-11-16 02:25:07"},
	{"YYYY-MM-DD hh:mm:ss", "   2025-11-16 02:25:07 and more"},
	{"?WW ?MMM ?D hh:mm:ss ?Z YYYY", "Sunday nov 16 02:25:07 +0100 2025"},
	{"WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Nov 16 02:25:07 GMT 2025"},
	{"WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Nov  6 02:25:07 EST 2025"},
	{"WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Jul  6 02:25:07 PDT 2025"},
	{"WW MMM _D hh:mm:ss ZZZ YYYY", "Sun Jul  6 02:25:07 XYZ 2025"},
	{"WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 XYZ 2025"},
	{"WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 ABCDEFGHIJKLMNO 2025"},
	{"WW MMM _D hh:mm:ss ?Z YYYY", "Sun Jul  6 02:25:07 AB 2025"},
	{"YYYY/M/D h:mm a", "2025/3/9 12:05 am"},
	{"YYYY/M/D h:mm a", "2025/3/9 12:05 PM"},
	{"YYYY/M/D h:mm A", "2025/3/9 1:05 pm"},
	{"YYYY/M/D h:mm a", "2025/3/9 13:05 pm"},
	{"~YYYY/M/D h:mm a", "2025/3/9 13:05 pm"},
	{"YYYY/M/D h:mm a", "2025/3/9 0:05 xm"},
	{"YYYY Z", "2025 +0530"},
	{"YYYY Z", "2025 -1400"},
	{"YYYY Z", "2025 +0560"},
	{"YYYY Z", "2025 +053"},
	{"YYYY ZZ", "2025 -05:30"},
	{"YYYY ZZ", "2025 +5:61"},
	{"YYYY ZZ", "2025 0530"},
	{"YYYY ?Z", "2025 +05:30"},
	{"YYYY ?Z", "2025 -0800"},
	{"YYYY ?Z", "2025 Z"},
	{"YYYY ZZZ", "2025 Z"},
	{"YYYY ZZZ", "2025 n"},
	{"YYYY ZZZ", "2025 UTC"},
	{"YYYY ZZZ", "2025 ut"},
	{"YYYY ZZZ", "2025 +0100"},
	{"YYYY ZZZZ", "2025 GMT"},
	{"YYYY zz", "2025 GMT"},
	{"YYYY z", "2025 +0200"},
	{"YY M D", "25 3 9"},
	{"Y", "1999"},
	{"?Y", "99"},
	{"?Y", "1999"},
	{"YYY", "2025"},
	{"MMMM D, YYYY", "March 9, 2025"},
	{"MMMM D, YYYY", "marc 9, 2025"},
	{"MMM D,YYYY", "mar   9 ,, 2025"},
	{"?M/D/YYYY", "March/9/2025"},
	{"?M/D/YYYY", "Mar/9/2025"},
	{"?M/D/YYYY", "3/9/2025"},
	{"Do MMM", "9th Mar"},
	{"Do MMM", "9 Mar"},
	{"W WW WWW", "2 Mon Monday"},
	{"?W", "tue"},
	{"?W", "3"},
	{"W", "9"},
	{"hh:mm:ss.ttt", "23:59:60.999"},
	{"hh:mm:ss.uuuu", "23:59:59.123456"},
	{"hh:mm:ss.nnnnnn", "01:02:03.123456789"},
	{"hh:mm:ss.?n", "01:02:03.5"},
	{"hh:mm", "24:00"},
	{"hh:mm", "25:00"},
	{"hh:mm", "12:60"},
	{"~hh:mm", "25:61"},
	{"YYYY-MM-DD", "2025-13-01"},
	{"~YYYY-MM-DD", "2025-13-01"},
	{"YYYY-MM-DD", "2025-02-29"},
	{"YYYY-MM-DD", "2024-02-29"},
	{"YYYY-MM-DD", "2025-02-00"},
	{"YYYY-MM-DD", "2025-00-10"},
	{"~YYYY-MM-DD", "2025-00-00"},
	{"YYYY-MM-DD", "2025-1-1"},
	{"YYYY-MM-DD", "25-01-01"},
	{"YYYY-MM-DD", ""},
	{"", ""},
	{"", "x"},
	{"[date:] YYYY", "date: 2025"},
	{"[date:] YYYY", "data: 2025"},
	{"[a[b]c\\]d] YYYY", "a[b]c]d 2025"},
	{"[open YYYY", "open 2025"},
	{"YYYY_MM", "2025 03"},
	{"YYYY MM", "2025,\t03"},
	{"YYYY MM", "2025x03"},
	{"DDD", "123"},
	{"hhh", "123"},
	{"q", "q"},
	{"q", "r"},
	{"YYYY-MM-DD hh:mm", "2025-07-04 12:00"},
	{"YYYY-MM-DD hh:mm", "2025-01-04 12:00"},
	{"YYYY-MM-DD hh:mm", "2025-03-09 02:30"},
	{"YYYY-MM-DD hh:mm", "2025-11-02 01:30"},
	{"YYYY-MM-DD hh:mm ZZZ", "2025-11-02 01:30 MST"},
	{"YYYY-MM-DD hh:mm ZZZ", "2025-07-04 12:00 EDT"},
	{"YYYY-MM-DD hh:mm Z", "2025-07-04 12:00 +0000"},
};

void
show(Tm *tm)
{
	Bprint(&bout, "%d %d:%d:%d.%d %d/%d/%d w%d y%d [%s] %d",
		tm->year, tm->hour, tm->min, tm->sec, tm->nsec,
		tm->mday, tm->mon, tm->year, tm->wday, tm->yday, tm->zone, tm->tzoff);
}

void
main(int argc, char **argv)
{
	char buf[256], *ep;
	Tzone *tz;
	vlong t;
	Tm tm;
	int a, i, j;

	Binit(&bout, 1, OWRITE);
	tmfmtinstall();
	for(a = 1; a < argc; a++){
		tz = nil;
		if(strcmp(argv[a], "nil") != 0){
			tz = tzload(argv[a]);
			if(tz == nil){
				Bprint(&bout, "zone %s: %r\n", argv[a]);
				continue;
			}
		}
		Bprint(&bout, "zone %s\n", argv[a]);
		for(i = 0; i < nelem(tms); i++){
			memset(&tm, 0, sizeof tm);
			tmtimens(&tm, tms[i], i*1001001, tz);
			Bprint(&bout, "time %lld: ", tms[i]);
			show(&tm);
			Bprint(&bout, "\n");
			for(j = 0; j < nelem(fmts); j++){
				snprint(buf, sizeof buf, "%τ", tmfmt(&tm, fmts[j]));
				Bprint(&bout, "\t%s|%s|\n", fmts[j] ? fmts[j] : "nil", buf);
			}
			Bprint(&bout, "\tasctime %s", asctime(&tm));
			t = tmnorm(&tm);
			Bprint(&bout, "\tnorm %lld ", t);
			show(&tm);
			Bprint(&bout, "\n");
		}
		for(i = 0; i < nelem(parses); i++){
			memset(&tm, 0, sizeof tm);
			Bprint(&bout, "parse %s|%s|: ", parses[i].fmt, parses[i].str);
			if(tmparse(&tm, parses[i].fmt, parses[i].str, tz, &ep) == nil){
				Bprint(&bout, "%r\n");
				continue;
			}
			show(&tm);
			Bprint(&bout, " end %d", (int)(ep - parses[i].str));
			t = tmnorm(&tm);
			Bprint(&bout, " norm %lld ", t);
			show(&tm);
			Bprint(&bout, "\n");
		}
		for(i = 0; i < 3000; i++){
			t = (vlong)next() >> 30;
			if(i % 3 == 0)
				t = (vlong)(next() >> 33);
			memset(&tm, 0, sizeof tm);
			tmtime(&tm, t, tz);
			Bprint(&bout, "%lld: ", t);
			show(&tm);
			snprint(buf, sizeof buf, "%τ", tmfmt(&tm, "YYYY-MM-DD WWW hh:mm:ss ZZ ZZZ"));
			Bprint(&bout, " %s %lld\n", buf, tmnorm(&tm));
		}
	}
	/* ctime and localtime, which take a long */
	Bprint(&bout, "ctime %s", ctime(0));
	Bprint(&bout, "ctime %s", ctime(1763259907));
	Bprint(&bout, "ctime %s", ctime(-1));
	Bprint(&bout, "ctime %s", ctime(0x7fffffff));
	show(localtime(1751652000));
	Bprint(&bout, "\n");
	show(gmtime(1751652000));
	Bprint(&bout, "\n");
	Bterm(&bout);
	exits(nil);
}
