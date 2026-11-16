/*
 * authtest - 9front's libauth, the client's half: the attribute lists
 * (attr.c), and the name space that newns and addns make from a file,
 * for comparison with planZ's Zig port (src/user/cmd/authtest.zig,
 * which prints the same lines).  Not part of 9front; compiled in the
 * guest by tools/usbzig.rc:
 *	6c -FTVw authtest.c && 6l -o authtest.stock authtest.6
 *
 * usage: authtest attr
 *	authtest newns [file]
 *	authtest addns file
 *
 * newns and addns change the name space of this process for good; it
 * then prints its own /proc/n/ns (by the device's name, whatever the
 * name space has become), its directory, and $user and $home.
 */
#include <u.h>
#include <libc.h>
#include <auth.h>

char *strs[] = {
	"proto=p9sk1 dom=example.com user=glenda !password=secret",
	"proto=p9any role=client",
	"user? dom=x !password?",
	"user? user=bob",
	"a=1 b a=2 c?",
	"'quoted name'='a value' q='it''s'",
	"x= y=''",
	"",
	"   ",
	"lone",
};

void
attrs(void)
{
	Attr *a, *b, *f;
	char *v;
	int i;

	fmtinstall('A', _attrfmt);
	quotefmtinstall();
	for(i = 0; i < nelem(strs); i++){
		a = _parseattr(strs[i]);
		print("[%s] -> [%A]\n", strs[i], a);
		b = _copyattr(a);
		print("  copy [%A]\n", b);
		f = _findattr(a, "user");
		print("  find user: %s\n", f != nil ? f->val : "(none)");
		v = _strfindattr(a, "a");
		print("  strfind a: %s\n", v != nil ? v : "(none)");
		b = _delattr(b, "user");
		b = _delattr(b, "a");
		print("  del user, a [%A]\n", b);
		_freeattr(a);
		_freeattr(b);
	}
	a = _mkattr(AttrQuery, "q", "", _mkattr(AttrDefault, "d", "v", _mkattr(AttrNameval, "n", "two words", nil)));
	print("made [%A]\n", a);
	_freeattr(a);
}

void
cat(char *name)
{
	char buf[8192];
	long n;
	int fd;

	fd = open(name, OREAD);
	if(fd < 0){
		print("open %s: %r\n", name);
		return;
	}
	while((n = read(fd, buf, sizeof buf)) > 0)
		write(1, buf, n);
	close(fd);
}

void
show(void)
{
	char name[64], wd[512];
	int fd;

	snprint(name, sizeof name, "#p/%d/ns", getpid());
	cat(name);
	if(getwd(wd, sizeof wd) == nil)
		print("getwd: %r\n");
	else
		print("wd %s\n", wd);
	print("user ");
	cat("#e/user");
	print("\nhome ");
	cat("#e/home");
	print("\n");
	fd = open("#A/volume", OREAD);
	if(fd < 0)
		print("audio: %r\n");
	else
		print("audio: opened\n");
}

void
main(int argc, char **argv)
{
	char *file;

	if(argc < 2)
		sysfatal("usage");
	file = argc > 2 ? argv[2] : nil;
	if(strcmp(argv[1], "attr") == 0)
		attrs();
	else if(strcmp(argv[1], "newns") == 0){
		print("newns %d\n", newns(getuser(), file));
		show();
	}else if(strcmp(argv[1], "addns") == 0){
		print("addns %d", addns(getuser(), file));
		print(" %r\n");
		show();
	}else
		sysfatal("usage");
	exits(nil);
}
