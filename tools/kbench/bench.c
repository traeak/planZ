/*
 * Kernel micro-benchmarks, for comparing planZ with 9front: the same
 * binary, compiled in the guest with 6c, runs on either kernel.
 * tools/kbench.sh drives it.
 *
 *	bench [-p nproc] [-q]
 *
 * Each test runs once with a tenth of its iterations to warm up,
 * then once timed with nsec().  Nothing is printed until all tests
 * are done, so that output does not disturb the timing.  -q divides
 * every count by 10, for trying it out.  -x exits at once; the exec
 * test runs the binary itself with it, so the path must be absolute.
 */
#include <u.h>
#include <libc.h>

enum {
	Nsys	= 5000000,
	Npipe	= 500000,
	Nfork	= 100000,
	Nbig	= 20000,
	Nexec	= 20000,
	Bigmem	= 16*1024*1024,
};

char	*self;
char	out[4096];
char	*op = out;
int	scale = 1;

void
usage(void)
{
	fprint(2, "usage: %s [-p nproc] [-q]\n", argv0);
	exits("usage");
}

void
report(char *name, long n, vlong ns)
{
	op = seprint(op, out+sizeof out, "bench %s n %ld ns %lld per %lld\n",
		name, n, ns, ns/n);
}

void
waitfor(void)
{
	Waitmsg *w;

	if((w = wait()) == nil)
		sysfatal("wait: %r");
	if(w->msg[0] != 0)
		sysfatal("child: %s", w->msg);
	free(w);
}

/* a system call that does almost nothing */
void
sysloop(long n)
{
	long i;
	int fd;

	if((fd = open("/dev/null", OREAD)) < 0)
		sysfatal("open: %r");
	for(i = 0; i < n; i++)
		seek(fd, 0, 0);
	close(fd);
}

/* one byte there and back through a pipe, between two processes */
void
pipeloop(long n)
{
	int p[2];
	long i;
	char c;

	if(pipe(p) < 0)
		sysfatal("pipe: %r");
	switch(fork()){
	case -1:
		sysfatal("fork: %r");
	case 0:
		for(i = 0; i < n; i++){
			if(read(p[1], &c, 1) != 1)
				sysfatal("read: %r");
			if(write(p[1], &c, 1) != 1)
				sysfatal("write: %r");
		}
		_exits(nil);
	}
	c = 'x';
	for(i = 0; i < n; i++){
		if(write(p[0], &c, 1) != 1)
			sysfatal("write: %r");
		if(read(p[0], &c, 1) != 1)
			sysfatal("read: %r");
	}
	waitfor();
	close(p[0]);
	close(p[1]);
}

/* create a process that exits at once, and wait for it */
void
forkloop(long n)
{
	long i;

	for(i = 0; i < n; i++){
		switch(fork()){
		case -1:
			sysfatal("fork: %r");
		case 0:
			_exits(nil);
		}
		waitfor();
	}
}

/* the same with 16MB of touched memory to share copy-on-write */
void
bigloop(long n)
{
	char *p;
	long i;

	if((p = malloc(Bigmem)) == nil)
		sysfatal("malloc: %r");
	for(i = 0; i < Bigmem; i += 4096)
		p[i] = i;
	forkloop(n);
	free(p);
}

/* create a process that runs this binary, which exits at once */
void
execloop(long n)
{
	long i;

	for(i = 0; i < n; i++){
		switch(fork()){
		case -1:
			sysfatal("fork: %r");
		case 0:
			execl(self, "bench", "-x", nil);
			sysfatal("exec %s: %r", self);
		}
		waitfor();
	}
}

/* nproc processes running forkloop at once */
int	npar = 1;

void
parloop(long n)
{
	int k;

	for(k = 0; k < npar; k++){
		switch(fork()){
		case -1:
			sysfatal("fork: %r");
		case 0:
			forkloop(n/npar);
			_exits(nil);
		}
	}
	for(k = 0; k < npar; k++)
		waitfor();
}

void
run(char *name, void (*f)(long), long n)
{
	vlong t;

	n /= scale;
	f(n/10);
	t = nsec();
	f(n);
	t = nsec() - t;
	report(name, n, t);
}

void
main(int argc, char **argv)
{
	vlong t0;

	ARGBEGIN{
	case 'x':
		exits(nil);
	case 'p':
		npar = atoi(EARGF(usage()));
		break;
	case 'q':
		scale = 10;
		break;
	default:
		usage();
	}ARGEND
	if(argc != 0 || npar < 1)
		usage();
	self = argv0;
	if(self[0] != '/')
		sysfatal("run me by an absolute path");

	t0 = nsec();
	run("syscall", sysloop, Nsys);
	run("pipe", pipeloop, Npipe);
	run("fork", forkloop, Nfork);
	run("fork16m", bigloop, Nbig);
	run("forkexec", execloop, Nexec);
	if(npar > 1){
		char name[32];

		snprint(name, sizeof name, "fork%dx", npar);
		run(name, parloop, Nfork);
	}
	op = seprint(op, out+sizeof out, "bench done total %lld\n", nsec()-t0);
	write(1, out, op-out);
	exits(nil);
}
