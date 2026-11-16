/*
 * locktest - processes that share memory (rfork with RFMEM) over
 * 9front's locks: Lock, QLock, RWLock, Rendez, the semaphores, the
 * atomic operations, and what each process keeps of its own (the
 * stack, privalloc's words, the pid, atexit's functions, the error
 * string), for comparison with planZ's Zig port
 * (src/user/cmd/locktest.zig, which prints the same lines).  After
 * 9front's libc/test/lock.c and atomic.c.  Not part of 9front;
 * compiled in the guest by tools/usbzig.rc:
 *	6c -FTVw locktest.c && 6l -o locktest.stock locktest.6
 *
 * Only the first process prints, and only what does not depend on
 * which process ran when.
 */
#include <u.h>
#include <libc.h>

enum {
	NP = 10,	/* processes of a kind */
	N = 2000,	/* turns each */
	NQ = 8,		/* places in the queue */
	NPROD = 4,
	NITEM = 500,
	NZ = 3,
};

int
spawn(void (*f)(void*), void *p)
{
	int pid;

	pid = rfork(RFMEM|RFPROC);
	switch(pid){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		f(p);
		exits(nil);
	}
	return pid;
}

void
waitall(int n)
{
	Waitmsg *w;

	while(n-- > 0){
		w = wait();
		if(w == nil)
			sysfatal("wait: %r");
		if(w->msg[0] != 0)
			print("child: %s\n", w->msg);
		free(w);
	}
}

/* how many wait in a queue */
int
queued(Lock *lk, QLp **head)
{
	QLp *p;
	int n;

	n = 0;
	lock(lk);
	for(p = *head; p != nil; p = p->next)
		n++;
	unlock(lk);
	return n;
}

/*
 * Lock and QLock: a sum
 */
Lock l;
QLock ql;
long counter;

void
linc(void *a)
{
	int i;

	for(i = 0; i < N; i++){
		lock(&l);
		counter += (uintptr)a;
		unlock(&l);
	}
}

void
ldec(void*)
{
	int i;

	for(i = 0; i < N; i++){
		lock(&l);
		counter--;
		unlock(&l);
	}
}

void
qinc(void *a)
{
	int i;

	for(i = 0; i < N; i++){
		qlock(&ql);
		counter += (uintptr)a;
		qunlock(&ql);
	}
}

void
qdec(void*)
{
	int i;

	for(i = 0; i < N; i++){
		qlock(&ql);
		counter--;
		qunlock(&ql);
	}
}

void
locks(void)
{
	int i;

	print("canlock %d", canlock(&l));
	unlock(&l);
	lock(&l);
	print(" %d", canlock(&l));
	unlock(&l);
	print(" %d\n", canlock(&l));
	unlock(&l);

	print("canqlock %d", canqlock(&ql));
	qunlock(&ql);
	qlock(&ql);
	print(" %d", canqlock(&ql));
	qunlock(&ql);
	print(" %d\n", canqlock(&ql));
	qunlock(&ql);

	counter = 0;
	for(i = 1; i <= NP; i++){
		spawn(linc, (void*)i);
		spawn(ldec, nil);
	}
	waitall(2*NP);
	print("lock: counter %ld\n", counter);

	counter = 0;
	for(i = 1; i <= NP; i++){
		spawn(qinc, (void*)i);
		spawn(qdec, nil);
	}
	waitall(2*NP);
	print("qlock: counter %ld\n", counter);
}

/*
 * RWLock: writers keep two numbers the same, readers look
 */
RWLock rw;
long rwa, rwb;
long rwbad;

void
writer(void*)
{
	int i;

	for(i = 0; i < N; i++){
		wlock(&rw);
		rwa++;
		if((i & 63) == 0)
			sleep(0);
		rwb++;
		wunlock(&rw);
	}
}

void
reader(void*)
{
	int i;

	for(i = 0; i < N; i++){
		rlock(&rw);
		if(rwa != rwb)
			ainc(&rwbad);
		if((i & 127) == 0)
			sleep(0);
		if(rwa != rwb)
			ainc(&rwbad);
		runlock(&rw);
	}
}

/* the order the lock is given in */
Lock loglk;
char rwlog[16];
long nlog;
Along go;

void
logc(int c)
{
	lock(&loglk);
	rwlog[nlog] = c;
	unlock(&loglk);
	ainc(&nlog);
}

void
ordw(void*)
{
	wlock(&rw);
	logc('W');
	wunlock(&rw);
}

void
ordr(void *a)
{
	rlock(&rw);
	logc((int)(uintptr)a);
	while(agetl(&go) == 0)
		sleep(1);
	runlock(&rw);
}

void
rwlocks(void)
{
	int i;

	print("canrlock %d", canrlock(&rw));
	print(" %d", canrlock(&rw));
	print(" canwlock %d", canwlock(&rw));
	runlock(&rw);
	runlock(&rw);
	print(" %d", canwlock(&rw));
	print(" canrlock %d", canrlock(&rw));
	print(" canwlock %d\n", canwlock(&rw));
	wunlock(&rw);

	for(i = 0; i < 4; i++){
		spawn(writer, nil);
		spawn(reader, nil);
	}
	waitall(8);
	print("rwlock: a %ld b %ld bad %ld\n", rwa, rwb, rwbad);

	/* a writer that waits keeps new readers out, and goes next */
	aswapl(&go, 1);
	rlock(&rw);
	spawn(ordw, nil);
	while(queued(&rw.lock, &rw.head) < 1)
		sleep(1);
	print("writer waits: canrlock %d canwlock %d", canrlock(&rw), canwlock(&rw));
	runlock(&rw);
	waitall(1);
	print(" log %s\n", rwlog);

	/*
	 * the writer lets go: the readers at the head of the queue go
	 * together, the writer behind them after the last of them, and
	 * the reader behind the writer after that
	 */
	nlog = 0;
	memset(rwlog, 0, sizeof rwlog);
	aswapl(&go, 0);
	wlock(&rw);
	for(i = 0; i < 3; i++){
		spawn(ordr, (void*)'R');
		while(queued(&rw.lock, &rw.head) < i+1)
			sleep(1);
	}
	spawn(ordw, nil);
	while(queued(&rw.lock, &rw.head) < 4)
		sleep(1);
	spawn(ordr, (void*)'r');
	while(queued(&rw.lock, &rw.head) < 5)
		sleep(1);
	wunlock(&rw);
	lock(&rw.lock);
	print("wunlock: readers %d writer %d", rw.readers, rw.writer);
	unlock(&rw.lock);
	print(" queued %d", queued(&rw.lock, &rw.head));
	while(nlog < 3)
		sleep(1);
	print(" canrlock %d", canrlock(&rw));
	aswapl(&go, 1);
	waitall(5);
	print(" log %s\n", rwlog);
}

/*
 * Rendez: a queue of NQ places between producers and consumers
 */
QLock qq;
Rendez nonempty, nonfull;
long qbuf[NQ];
int qrp, qwp, qn;
int taken;
vlong qsum;
int last[NPROD];
int qbad;

void
producer(void *a)
{
	int i, id;

	id = (uintptr)a;
	for(i = 0; i < NITEM; i++){
		qlock(&qq);
		while(qn == NQ)
			rsleep(&nonfull);
		qbuf[qwp++ % NQ] = id*1000 + i;
		qn++;
		rwakeup(&nonempty);
		qunlock(&qq);
	}
}

void
consumer(void*)
{
	long v;

	for(;;){
		qlock(&qq);
		while(qn == 0 && taken < NPROD*NITEM)
			rsleep(&nonempty);
		if(qn == 0){
			qunlock(&qq);
			break;
		}
		v = qbuf[qrp++ % NQ];
		qn--;
		taken++;
		qsum += v;
		if(v%1000 <= last[v/1000])
			qbad++;
		last[v/1000] = v%1000;
		if(taken == NPROD*NITEM)
			rwakeupall(&nonempty);
		rwakeup(&nonfull);
		qunlock(&qq);
	}
}

QLock sq;
Rendez sr;
int woke;

void
sleeper(void*)
{
	qlock(&sq);
	rsleep(&sr);
	woke++;
	qunlock(&sq);
}

void
rendez(void)
{
	int i;

	nonempty.l = &qq;
	nonfull.l = &qq;
	for(i = 0; i < NPROD; i++)
		last[i] = -1;
	for(i = 0; i < NPROD; i++){
		spawn(consumer, nil);
		spawn(producer, (void*)i);
	}
	waitall(2*NPROD);
	print("queue: taken %d sum %lld bad %d left %d\n", taken, qsum, qbad, qn);

	sr.l = &sq;
	qlock(&sq);
	print("rwakeup: none %d", rwakeup(&sr));
	qunlock(&sq);
	for(i = 0; i < 3; i++)
		spawn(sleeper, nil);
	while(queued(&sq.lock, &sr.head) < 3)
		sleep(1);
	qlock(&sq);
	print(" all %d", rwakeupall(&sr));
	print(" none %d", rwakeup(&sr));
	print(" woke %d", woke);
	qunlock(&sq);
	waitall(3);
	print(" woke %d\n", woke);
}

/*
 * semaphores
 */
long sem;
long semgot;

void
semwaiter(void*)
{
	if(semacquire(&sem, 1) == 1)
		ainc(&semgot);
}

void
sems(void)
{
	int i;

	for(i = 0; i < 5; i++)
		spawn(semwaiter, nil);
	print("sem: release %ld", semrelease(&sem, 5));
	waitall(5);
	print(" got %ld sem %ld", semgot, sem);
	print(" acquire %d", semacquire(&sem, 0));
	print(" tsemacquire %d", tsemacquire(&sem, 20));
	print(" release %ld", semrelease(&sem, 2));
	print(" acquire %d", semacquire(&sem, 0));
	print(" tsemacquire %d", tsemacquire(&sem, 20));
	print(" sem %ld\n", sem);
}

/*
 * a process's own: the stack, privalloc's words, the pid, atexit,
 * the error string
 */
void **priv;
int shared;
int childpid;
int cran, dontran, pran;
long errbad;

void
cexit(void)
{
	cran++;
}

void
cdont(void)
{
	dontran++;
}

void
pexit(void)
{
	pran++;
	print("atexit: the first process's ran, %d time\n", pran);
}

void
own(void *a)
{
	*(int*)a = 2;
	*priv = (void*)2;
	shared = 2;
	childpid = getpid();
	atexit(cexit);
	atexit(cdont);
	atexitdont(cdont);
}

void
errproc(void *a)
{
	char want[32], buf[ERRMAX];
	int i;

	snprint(want, sizeof want, "process %d", (int)(uintptr)a);
	werrstr("%s", want);
	for(i = 0; i < 500; i++){
		snprint(buf, sizeof buf, "%r");
		if(strcmp(buf, want) != 0)
			ainc(&errbad);
		if((i & 31) == 0)
			sleep(0);
	}
}

void
owns(void)
{
	int i, n, local, pid;
	void **p;

	n = 0;
	priv = nil;
	for(i = 0; i < 20; i++){
		p = privalloc();
		if(p != nil){
			n++;
			priv = p;
		}
	}
	print("privalloc: %d words\n", n);

	local = 1;
	*priv = (void*)1;
	shared = 1;
	atexit(pexit);
	pid = spawn(own, &local);
	waitall(1);
	print("own: stack %d private %d data %d pid %d %d\n",
		local, (int)(uintptr)*priv, shared, pid == childpid, getpid() == childpid);
	print("atexit: child's %d taken back %d first's %d\n", cran, dontran, pran);

	werrstr("the first process");
	for(i = 1; i <= NP; i++)
		spawn(errproc, (void*)i);
	waitall(NP);
	print("errstr: bad %ld mine %r\n", errbad);
}

/*
 * the library under several processes: malloc and the time zones
 */
long membad;
Tzone *tzp[NP][NZ];
char *zname[NZ] = { nil, "US_Eastern", "CET" };

void
memproc(void *a)
{
	uchar *b[16];
	int sz[16];
	int i, j, k, id;
	uint r;

	id = (uintptr)a;
	r = id * 2654435761U;
	memset(b, 0, sizeof b);
	for(i = 0; i < 2000; i++){
		r = r*1103515245 + 12345;
		k = (r >> 16) % nelem(b);
		if(b[k] != nil){
			for(j = 0; j < sz[k]; j++)
				if(b[k][j] != id){
					ainc(&membad);
					break;
				}
			free(b[k]);
		}
		sz[k] = 1 + (r >> 8) % 700;
		b[k] = malloc(sz[k]);
		if(b[k] == nil){
			ainc(&membad);
			continue;
		}
		memset(b[k], id, sz[k]);
	}
	for(k = 0; k < nelem(b); k++)
		free(b[k]);
}

void
tzproc(void *a)
{
	int i, k, id;

	id = (uintptr)a;
	for(i = 0; i < 20; i++)
		for(k = 0; k < NZ; k++)
			tzp[id][k] = tzload(zname[k]);
}

void
library(void)
{
	int i, k, bad;

	for(i = 1; i <= NP; i++)
		spawn(memproc, (void*)i);
	waitall(NP);
	print("malloc: bad %ld\n", membad);

	for(i = 0; i < NP; i++)
		spawn(tzproc, (void*)i);
	waitall(NP);
	bad = 0;
	for(i = 0; i < NP; i++)
		for(k = 0; k < NZ; k++)
			if(tzp[i][k] == nil || tzp[i][k] != tzp[0][k])
				bad++;
	print("tzload: bad %d again %d other %d none %d\n", bad,
		tzload("CET") == tzp[0][2], tzp[0][1] != tzp[0][2], tzload("nosuchzone") == nil);
}

/*
 * the atomic operations (libc/test/atomic.c, with fewer processes)
 */
Along acount;
Along done0, done1;
long val0, val1;
long atbad;
long ncount;

void
inc(void *p)
{
	int i;

	for(i = 0; i < 10000; i++)
		aincl(p, 1);
}

void
dec(void *p)
{
	int i;

	for(i = 0; i < 10000; i++)
		aincl(p, -1);
}

void
casinc(void *p)
{
	int i;
	long v;

	for(i = 0; i < 2000; i++) do{
		v = agetl(p);
	}while(!acasl(p, v, v+1));
}

void
casdec(void *p)
{
	int i;
	long v;

	for(i = 0; i < 2000; i++) do{
		v = agetl(p);
	}while(!acasl(p, v, v-1));
}

void
ninc(void*)
{
	int i;

	for(i = 0; i < 10000; i++)
		ainc(&ncount);
}

void
ndec(void*)
{
	int i;

	for(i = 0; i < 10000; i++)
		adec(&ncount);
}

void
toggle0(void*)
{
	val0 = 1;
	aswapl(&done0, 1);
	while(agetl(&done1) != 1)
		/* wait */;
	if(val1 != 1)
		ainc(&atbad);
}

void
toggle1(void*)
{
	val1 = 1;
	aswapl(&done1, 1);
	while(agetl(&done0) != 1)
		/* wait */;
	if(val0 != 1)
		ainc(&atbad);
}

void
atomics(void)
{
	Along l;
	Avlong v;
	Aptr p;
	int i;
	long n;

	aswapl(&l, 1);
	print("along: %ld", agetl(&l));
	print(" %ld", aincl(&l, 1));
	print(" %ld", aincl(&l, -1));
	print(" %d", acasl(&l, 42, 123));
	print(" %ld", agetl(&l));
	print(" %ld", aswapl(&l, 77));
	print(" %d", acasl(&l, 77, 42));
	print(" %ld\n", agetl(&l));

	aswapv(&v, 1);
	print("avlong: %lld", agetv(&v));
	print(" %lld", aincv(&v, 1LL<<40));
	print(" %lld", aincv(&v, -1));
	print(" %d", acasv(&v, 42, 123));
	print(" %lld", agetv(&v));
	print(" %lld", aswapv(&v, 77));
	print(" %d", acasv(&v, 77, -42));
	print(" %lld\n", agetv(&v));

	aswapp(&p, &v);
	print("aptr: %d", agetp(&p) == &v);
	print(" %d", acasp(&p, &l, &i));
	print(" %d", agetp(&p) == &v);
	print(" %d", acasp(&p, &v, &i));
	print(" %d", agetp(&p) == &i);
	print(" %d\n", aswapp(&p, nil) == &i);

	n = 5;
	print("ainc: %ld", ainc(&n));
	print(" %ld", adec(&n));
	print(" %ld\n", n);

	for(i = 0; i < 10; i++){
		spawn(inc, &acount);
		spawn(dec, &acount);
	}
	waitall(20);
	print("aincl: counter %ld\n", agetl(&acount));

	for(i = 0; i < 20; i++){
		spawn(casinc, &acount);
		spawn(casdec, &acount);
	}
	waitall(40);
	print("acasl: counter %ld\n", agetl(&acount));

	for(i = 0; i < 10; i++){
		spawn(ninc, nil);
		spawn(ndec, nil);
	}
	waitall(20);
	print("ainc: counter %ld\n", ncount);

	/* do the atomics act as barriers? */
	for(i = 0; i < 200; i++){
		val0 = 0;
		val1 = 0;
		aswapl(&done0, 0);
		aswapl(&done1, 0);
		spawn(toggle0, nil);
		spawn(toggle1, nil);
		waitall(2);
	}
	print("barrier: bad %ld\n", atbad);
}

void
main(void)
{
	locks();
	rwlocks();
	rendez();
	sems();
	owns();
	library();
	atomics();
	print("done\n");
	exits(nil);
}
