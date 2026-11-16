/*
 * threadtest - 9front's libthread: threads and their order, channels,
 * alt, chanclose, threadint and threadkill, QLock and Rendez between
 * threads, notes, procs, procexec, and the I/O procs, for comparison
 * with planZ's Zig port (src/user/cmd/threadtest.zig, which prints the
 * same lines).  Not part of 9front; compiled in the guest by
 * tools/usbzig.rc:
 *	6c -FTVw threadtest.c && 6l -o threadtest.stock threadtest.6
 *
 * Only the first proc prints.  Everything up to "procs" runs in one
 * proc, so that alt's random choices (libc's nrand) are the same in
 * both programs.  It exits through threadexitsall with the status
 * "bye".
 */
#include <u.h>
#include <libc.h>
#include <thread.h>

enum {
	STACK = 16*1024,
};

int mainstacksize = 32*1024;

char logbuf[1024];
char *logp = logbuf;

void
lg(char *fmt, ...)
{
	va_list arg;

	va_start(arg, fmt);
	logp = vseprint(logp, logbuf+sizeof logbuf, fmt, arg);
	va_end(arg);
}

void
flush(char *name)
{
	print("%s:%s\n", name, logbuf);
	logp = logbuf;
	logbuf[0] = 0;
}

void
yields(int n)
{
	while(n-- > 0)
		yield();
}

/*
 * threads: the order they run in, ids, groups, names, data
 */
int ndone;

void
abc(void *a)
{
	int i;

	for(i = 0; i < 3; i++){
		lg(" %c%d", (int)(uintptr)a, i);
		yield();
	}
	ndone++;
}

int kidgrp, kidid;

void
kid(void*)
{
	kidgrp = threadgetgrp();
	kidid = threadid();
	*threaddata() = (void*)22;
	*procdata() = (void*)5;
	threadsetname("kid %d", 1);
	lg(" name %s", threadgetname());
	ndone++;
}

void
threads(void)
{
	int id[3], i, og;

	lg(" main %d", threadid());
	for(i = 0; i < 3; i++)
		id[i] = threadcreate(abc, (void*)('a'+i), STACK);
	lg(" ids %d %d %d", id[0], id[1], id[2]);
	while(ndone < 3){
		lg(" m");
		yield();
	}
	flush("order");

	ndone = 0;
	og = threadsetgrp(7);
	*threaddata() = (void*)11;
	i = threadcreate(kid, nil, STACK);
	yields(2);
	lg(" grp %d %d %d id %d", og, threadgetgrp(), kidgrp, kidid == i);
	lg(" data %d %d", (int)(uintptr)*threaddata(), (int)(uintptr)*procdata());
	lg(" name %s", threadgetname());
	lg(" pid %d %d %d", threadpid(0) == getpid(), threadpid(threadid()) == getpid(), threadpid(i));
	threadsetgrp(0);
	flush("ids");
}

/*
 * channels with and without a buffer
 */
Channel *c0, *c3;

void
sender(void*)
{
	int i;

	for(i = 1; i <= 4; i++){
		lg(" s%d", i);
		sendul(c0, i);
	}
	lg(" s.");
}

void
rcvr(void *a)
{
	ulong v;
	int r;

	r = recv(c0, &v);
	lg(" %c=%d,%lud", (int)(uintptr)a, r, r > 0 ? v : 0);
	ndone++;
}

void
chans(void)
{
	int i;
	ulong v;

	c0 = chancreate(sizeof(ulong), 0);
	c3 = chancreate(sizeof(ulong), 3);
	threadcreate(sender, nil, STACK);
	for(i = 1; i <= 4; i++){
		v = recvul(c0);
		lg(" r%lud", v);
	}
	yield();
	flush("unbuffered");

	for(i = 1; i <= 5; i++)
		lg(" %d", nbsendul(c3, i));
	lg(" /");
	for(i = 1; i <= 5; i++)
		lg(" %lud", nbrecvul(c3));
	lg(" / %d %d", nbsend(c0, &v), nbrecv(c0, &v));
	flush("buffered");

	/* three wait to receive; which gets which value is alt's choice */
	ndone = 0;
	for(i = 0; i < 3; i++)
		threadcreate(rcvr, (void*)('x'+i), STACK);
	yield();
	for(i = 1; i <= 3; i++)
		sendul(c0, 10*i);
	while(ndone < 3)
		yield();
	flush("waiters");
}

/*
 * alt
 */
void
alts(void)
{
	Channel *a1, *a2;
	Alt a[5];
	ulong v, w;
	int i, r;

	a1 = chancreate(sizeof(ulong), 1);
	a2 = chancreate(sizeof(ulong), 1);
	memset(a, 0, sizeof a);
	a[0].c = a1; a[0].v = &v; a[0].op = CHANRCV;
	a[1].c = a2; a[1].v = &v; a[1].op = CHANRCV;
	a[2].op = CHANEND;
	for(i = 0; i < 24; i++){
		nbsendul(a1, 1);
		nbsendul(a2, 2);
		lg("%d", alt(a));
	}
	flush("alt choice");

	nbrecvul(a1);
	nbrecvul(a2);
	a[2].op = CHANNOBLK;
	lg(" %d", alt(a));
	a[0].op = CHANNOP;
	sendul(a1, 5);
	sendul(a2, 6);
	r = alt(a);
	lg(" %d,%lud", r, v);
	a[0].op = CHANRCV;
	a[1].op = CHANNOP;
	r = alt(a);
	lg(" %d,%lud", r, v);
	/* a send and a receive: only the send can go */
	w = 9;
	a[0].c = a1; a[0].v = &v; a[0].op = CHANRCV;
	a[1].c = a2; a[1].v = &w; a[1].op = CHANSND;
	a[2].op = CHANEND;
	lg(" %d", alt(a));
	/* both can go: the choice is alt's */
	a[0].c = a2;
	a[1].c = a1;
	lg(" %d", alt(a));
	lg(" %lud", nbrecvul(a1));
	lg(" %lud", nbrecvul(a2));
	a[0].c = nil;
	lg(" %d", alt(a));
	flush("alt");
	chanfree(a1);
	chanfree(a2);
}

/*
 * chanclose
 */
Channel *cc;

void
closedrcv(void*)
{
	ulong v;

	lg(" blocked=%d", recv(cc, &v));
	ndone++;
}

void
closes(void)
{
	Channel *c, *d;
	Alt a[3];
	ulong v;
	int r;

	c = chancreate(sizeof(ulong), 3);
	sendul(c, 1);
	sendul(c, 2);
	lg(" %d", chanclosing(c));
	lg(" %d", chanclose(c));
	lg(" %d", chanclosing(c));
	v = 0;
	r = recv(c, &v);
	lg(" %d,%lud", r, v);
	lg(" %d", chanclosing(c));
	r = nbrecv(c, &v);
	lg(" %d,%lud", r, v);
	lg(" %d", recv(c, &v));
	lg(" %d", nbrecv(c, &v));
	lg(" %d", send(c, &v));
	lg(" %d", nbsend(c, &v));
	lg(" %d", chanclose(c));
	lg(" %d", chanclosing(c));
	flush("close");

	ndone = 0;
	cc = chancreate(sizeof(ulong), 0);
	threadcreate(closedrcv, nil, STACK);
	yield();
	lg(" %d", chanclose(cc));
	while(ndone < 1)
		yield();

	/* all of an alt's channels closed: the last one, then nothing */
	d = chancreate(sizeof(ulong), 0);
	chanclose(d);
	memset(a, 0, sizeof a);
	a[0].c = c; a[0].v = &v; a[0].op = CHANRCV;
	a[1].c = d; a[1].v = &v; a[1].op = CHANSND;
	a[2].op = CHANEND;
	lg(" alt %d", alt(a));
	lg(" %d", a[1].err != nil);
	lg(" %d", alt(a));
	a[1].op = CHANNOP;
	lg(" %d", alt(a));
	flush("closed");
	chanfree(c);
	chanfree(d);
	chanfree(cc);
}

/*
 * threadint, threadkill, threadkillgrp
 */
Channel *ic, *kc, *gc;
int woken;

void
victim(void *a)
{
	ulong v;
	int r;

	r = recv(ic, &v);
	lg(" %c:%d", (int)(uintptr)a, r);
	woken++;
	r = recv(ic, &v);
	lg(" %c:%d,%lud", (int)(uintptr)a, r, v);
	woken++;
}

void
killvictim(void*)
{
	ulong v;

	recv(kc, &v);
	woken += 100;
}

void
grpvictim(void*)
{
	ulong v;

	recv(gc, &v);
	woken++;
}

void
kills(void)
{
	int a, b, i;

	ic = chancreate(sizeof(ulong), 0);
	woken = 0;
	kc = chancreate(sizeof(ulong), 0);
	a = threadcreate(victim, (void*)'a', STACK);
	b = threadcreate(killvictim, nil, STACK);
	yield();
	threadint(a);
	yields(2);
	lg(" woken %d", woken);
	sendul(ic, 7);
	yields(2);
	lg(" woken %d", woken);
	threadkill(b);
	yields(3);
	lg(" killed: woken %d pid %d %d", woken, threadpid(a), threadpid(b));
	flush("int");

	/*
	 * a channel that a killed thread waited on is not used again:
	 * its place in the channel's queue stays, and the next to meet
	 * it would wait for ever
	 */
	woken = 0;
	gc = chancreate(sizeof(ulong), 0);
	threadsetgrp(9);
	for(i = 0; i < 3; i++)
		threadcreate(grpvictim, nil, STACK);
	threadsetgrp(0);
	yield();
	threadintgrp(9);
	yields(3);
	lg(" intgrp %d", woken);
	gc = chancreate(sizeof(ulong), 0);
	threadsetgrp(9);
	for(i = 0; i < 3; i++)
		threadcreate(grpvictim, nil, STACK);
	threadsetgrp(0);
	yield();
	threadkillgrp(9);
	yields(3);
	lg(" killgrp %d", woken);
	flush("grp");
}

/*
 * libc's QLock and Rendez between threads, Ref, chanprint
 */
QLock tq;
Rendez tr;
int ready;
Ref ref;
Channel *pc;

void
holder(void*)
{
	qlock(&tq);
	lg(" h1");
	yield();
	lg(" h2");
	qunlock(&tq);
	lg(" h3");
	ndone++;
}

void
waiter(void*)
{
	lg(" w1");
	qlock(&tq);
	lg(" w2");
	while(!ready)
		rsleep(&tr);
	lg(" w3");
	qunlock(&tq);
	ndone++;
}

void
printer(void*)
{
	lg(" sent %d", chanprint(pc, "%d-%s", 7, "seven"));
	ndone++;
}

void
qlocks(void)
{
	char *s;

	ndone = 0;
	tr.l = &tq;
	threadcreate(holder, nil, STACK);
	threadcreate(waiter, nil, STACK);
	yields(4);
	qlock(&tq);
	lg(" m1 %d", rwakeup(&tr));
	ready = 1;
	qunlock(&tq);
	while(ndone < 2)
		yield();
	lg(" %d", canqlock(&tq));
	qunlock(&tq);
	flush("qlock");

	incref(&ref);
	incref(&ref);
	lg(" %ld", decref(&ref));
	lg(" %ld", decref(&ref));
	needstack(100);
	ndone = 0;
	pc = chancreate(sizeof(char*), 0);
	threadcreate(printer, nil, STACK);
	s = recvp(pc);
	lg(" got %s", s);
	free(s);
	while(ndone < 1)
		yield();
	flush("ref");
}

/*
 * notes
 */
char gotnote[ERRMAX];
int nnote;

int
onnote(void*, char *s)
{
	if(strncmp(s, "test", 4) != 0)
		return 0;
	strcpy(gotnote, s);
	nnote++;
	return 1;
}

void
notes(void)
{
	lg(" %d", threadnotify(onnote, 1));
	postnote(PNPROC, getpid(), "test one");
	lg(" %d %s", nnote, gotnote);
	postnote(PNPROC, getpid(), "test two");
	lg(" %d %s", nnote, gotnote);
	lg(" %d", threadnotify(onnote, 0));
	lg(" %d", threadnotify(onnote, 0));
	flush("note");
}

/*
 * procs
 */
Channel *req, *rep, *many, *intc, *msgc;

void
doubler(void*)
{
	ulong v;

	*procdata() = (void*)77;
	for(;;){
		v = recvul(req);
		if(v == 0)
			break;
		sendul(rep, 2*v);
	}
	sendul(rep, getpid());
	threadexits(nil);
}

void
producer(void *a)
{
	int i, id;

	id = (uintptr)a;
	for(i = 0; i < 100; i++)
		sendul(many, id*1000 + i);
}

void
intproc(void*)
{
	ulong v;
	int r;

	sendul(msgc, 1);
	r = recv(intc, &v);
	sendul(msgc, r);
	r = recv(intc, &v);		/* killed here */
	sendul(msgc, 100+r);
}

void
closer(void *a)
{
	close((int)(uintptr)a);
	sendul(msgc, 0);
}

void
procs(void)
{
	int i, id, last[4], bad, p[2];
	ulong v, sum;

	req = chancreate(sizeof(ulong), 0);
	rep = chancreate(sizeof(ulong), 0);
	id = proccreate(doubler, nil, STACK);
	for(i = 1; i <= 5; i++){
		sendul(req, i);
		lg(" %lud", recvul(rep));
	}
	lg(" pid %d %d", threadpid(id) > 0, threadpid(id) != getpid());
	i = threadpid(id);
	sendul(req, 0);
	lg(" %d", recvul(rep) == i);
	lg(" data %d", (int)(uintptr)*procdata());
	flush("proc");

	many = chancreate(sizeof(ulong), 4);
	for(i = 0; i < 4; i++){
		last[i] = -1;
		proccreate(producer, (void*)i, STACK);
	}
	sum = 0;
	bad = 0;
	for(i = 0; i < 400; i++){
		v = recvul(many);
		sum += v;
		if((int)(v%1000) <= last[v/1000])
			bad++;
		last[v/1000] = v%1000;
	}
	lg(" sum %lud bad %d", sum, bad);
	flush("procs");

	/* a thread of another proc, waiting: interrupted, then killed */
	intc = chancreate(sizeof(ulong), 0);
	msgc = chancreate(sizeof(ulong), 0);
	id = proccreate(intproc, nil, STACK);
	recvul(msgc);
	sleep(300);
	threadint(id);
	lg(" int %d", (int)recvul(msgc));
	sleep(300);
	threadkill(id);
	sleep(300);
	lg(" killed %d", threadpid(id));
	flush("procint");

	/* file descriptors: shared, and with RFFDG the proc's own */
	pipe(p);
	i = dup(p[1], -1);
	proccreate(closer, (void*)i, STACK);
	recvul(msgc);
	lg(" shared %d", write(i, "x", 1));
	i = dup(p[1], -1);
	procrfork(closer, (void*)i, STACK, RFFDG);
	recvul(msgc);
	lg(" own %d", write(i, "x", 1));
	close(i);
	close(p[0]);
	close(p[1]);
	flush("rfork");
}

/*
 * procexec and threadwaitchan
 */
Channel *pidc, *errc;
char *eargs[4];
char *eprog;

void
execproc(void*)
{
	char err[ERRMAX];

	procexec(pidc, eprog, eargs);
	rerrstr(err, sizeof err);
	sendp(errc, strdup(err));
}

void
execs(void)
{
	Channel *wc;
	Waitmsg *w;
	ulong pid;
	char *s;

	wc = threadwaitchan();
	pidc = chancreate(sizeof(ulong), 0);
	errc = chancreate(sizeof(char*), 0);

	eprog = "/bin/echo";
	eargs[0] = "echo";
	eargs[1] = "exec:";
	eargs[2] = "echo ran";
	eargs[3] = nil;
	proccreate(execproc, nil, STACK);
	pid = recvul(pidc);
	w = recvp(wc);
	lg(" pid %d %d msg [%s]", pid != ~0, w->pid == pid, w->msg);
	free(w);

	eprog = "/bin/test";
	eargs[0] = "test";
	eargs[1] = "-e";
	eargs[2] = "/no/such/file";
	proccreate(execproc, nil, STACK);
	pid = recvul(pidc);
	w = recvp(wc);
	lg(" pid %d %d failed %d", pid != ~0, w->pid == pid, w->msg[0] != 0);
	free(w);

	eprog = "/no/such/program";
	proccreate(execproc, nil, STACK);
	pid = recvul(pidc);
	s = recvp(errc);
	lg(" pid %d err [%s]", pid != ~0, s);
	free(s);
	flush("procexec");
}

/*
 * I/O procs
 */
Ioproc *io;
int iop[2];
Channel *ioc;

void
ioreader(void*)
{
	char buf[16], err[ERRMAX];
	long n;

	n = ioread(io, iop[0], buf, sizeof buf);
	rerrstr(err, sizeof err);
	lg(" read %ld [%s]", n, n < 0 ? err : "");
	sendul(ioc, 0);
}

void
ios(void)
{
	char buf[16];
	long n;
	int fd, id;

	io = ioproc();
	pipe(iop);
	lg(" write %ld", iowrite(io, iop[1], "hello", 5));
	n = ioread(io, iop[0], buf, sizeof buf);
	lg(" read %ld %.*s", n, (int)n, buf);
	iowrite(io, iop[1], "abc", 3);
	iowrite(io, iop[1], "def", 3);
	n = ioreadn(io, iop[0], buf, 6);
	lg(" readn %ld %.*s", n, (int)n, buf);
	lg(" sleep %d", iosleep(io, 10));
	lg(" flush %d", ioflush(io));
	fd = ioopen(io, "/dev/null", OREAD);
	lg(" open %d", fd >= 0);
	lg(" close %d", ioclose(io, fd));
	lg(" open %d", ioopen(io, "/no/such/file", OREAD));
	flush("io");

	/* a read that waits, broken off by threadint */
	ioc = chancreate(sizeof(ulong), 0);
	id = threadcreate(ioreader, nil, STACK);
	yields(3);	/* until it waits for the I/O proc's answer */
	sleep(300);
	threadint(id);
	recvul(ioc);
	lg(" write %ld", iowrite(io, iop[1], "again", 5));
	n = ioread(io, iop[0], buf, sizeof buf);
	lg(" read %ld %.*s", n, (int)n, buf);
	closeioproc(io);
	flush("iointr");
}

/*
 * the end: threadexitsall from another proc, with threads and procs
 * left waiting
 */
Channel *never;

void
stuck(void*)
{
	recvul(never);
}

void
ender(void*)
{
	threadexitsall("bye");
}

void
threadmain(int, char**)
{
	threads();
	chans();
	alts();
	closes();
	kills();
	qlocks();
	notes();
	print("procs\n");
	procs();
	execs();
	ios();
	never = chancreate(sizeof(ulong), 0);
	threadcreate(stuck, nil, STACK);
	proccreate(stuck, nil, STACK);
	print("done\n");
	proccreate(ender, nil, STACK);
	recvul(never);
	print("not reached\n");
}
