/*
 * Replay on 9front's pool.c the operations that src/kernel/pooltest.zig
 * runs on port/pool.zig, and print what came of them: for each
 * configuration and seed, a hash over every operation's result (the
 * address returned, as an offset into the arena memory) and over the
 * pool's cursize and curfree after it.  The Zig test holds the same
 * lines as its `want` text.
 *
 * Everything here that decides what is done has its twin in
 * pooltest.zig (Conf, the tables, rnd, pick, balloc, bmerge, moved,
 * step); change both or neither.
 *
 * What is left out of the comparison, because pool.zig differs from
 * the C on purpose there (see its header): the value of poolmsize for
 * a block whose data does not start at the start of the block, which
 * is never asked for; curalloc, which the C gets wrong after one path
 * of poolrealloc; and what makes the C corrupt its pool: POOL_NOREUSE
 * together with aligned blocks, alignments that are not multiples of
 * the quantum, 0 bytes with a span, and poolrealloc on a pool that
 * compacts.
 */
#include <u.h>
#include <libc.h>
#include <pool.h>

extern void *mapregion(uintptr, uintptr);
extern void unmapregion(void*, uintptr);
extern uintptr envnum(char*, uintptr);
extern void flushout(void);
extern int strcmp(const char*, const char*);
extern int atoi(const char*);

enum {
	Nslot = 256,
	Base = 0x20000000,
	Regsize = 96*1024*1024,
	Xhdr = 16,	/* what xalloc.zig puts in front of an allocation */
	Xslack = 16,	/* and what it adds behind */
	Nchunk = 8192,
};

typedef struct Slot Slot;
struct Slot {
	uchar *p;
	ulong n;
	int aligned;	/* from poolallocalign, and not through poolrealloc since */
	int moved;	/* by poolcompact: where it is no longer says anything */
};

typedef struct Conf Conf;
struct Conf {
	char *name;
	int flags;
	ulong quantum;
	ulong minarena;
	ulong minblock;
	ulong maxsize;
	int failevery;	/* every nth request for an arena fails */
	int gapevery;	/* every nth arena is not adjacent to the one before */
	int align;	/* use poolallocalign */
	int compact;	/* set Pool.move and call poolcompact */
	int nops;
};

static Conf conf[] = {
	{"A", 0, 32, 32*1024, 0, 4*1024*1024, 0, 3, 1, 0, 20000},
	{"B", 0, 32, 32*1024, 0, 1*1024*1024, 5, 0, 1, 0, 20000},
	{"C", POOL_NOREUSE, 32, 64*1024, 0, 64*1024*1024, 0, 2, 0, 0, 4000},
	{"D", 0, 32, 16*1024, 0, 768*1024, 0, 4, 1, 1, 20000},
	{"E", 0, 64, 4*1024, 128, 2*1024*1024, 7, 2, 1, 0, 20000},
	{"F", POOL_TOLERANCE, 32, 128*1024, 0, 8*1024*1024, 0, 4, 1, 0, 20000},
	{"G", 0, 32, 2*1024, 0, 1*1024*1024, 0, 0, 0, 1, 20000},
};

/* no alignment that is not a multiple of the quantum and is large
 * enough for freefromfront to act on: the C corrupts the pool then */
static ulong aligns[] = {0, 1, 8, 16, 32, 64, 256, 4096, 12, 96};
static int offs[] = {0, 0, 0, 4, 8, -8, -4, 20, 3};
static ulong spans[] = {0, 0, 0, 4096, 65536, 256};

typedef struct Chunk Chunk;
struct Chunk {
	uintptr a;
	uintptr n;
};

static Conf *cf;
static Slot slot[Nslot];
static Chunk chunk[Nchunk];
static int nchunk;
static uintptr brk;
static int ncall;
static uint rndx;
static uvlong hash;
static int trace;
static Pool pool;

static uint
rnd(void)
{
	rndx ^= rndx << 13;
	rndx ^= rndx >> 17;
	rndx ^= rndx << 5;
	return rndx;
}

static void
mix(uvlong v)
{
	int i;

	for(i = 0; i < 8; i++){
		hash ^= (v >> (8*i)) & 0xFF;
		hash *= 0x100000001b3ULL;
	}
}

/*
 * The coarse allocator, shaped like xalloc: a header in front, a
 * little slack behind, one allocation after the other unless a gap is
 * asked for, addresses that are multiples of 16, memory that is zero.
 */
static void*
balloc(ulong n)
{
	uintptr a;

	ncall++;
	if(cf->failevery && ncall % cf->failevery == 0)
		return nil;
	if(cf->gapevery && ncall % cf->gapevery == 0)
		brk += 4096;
	a = brk + Xhdr;
	if(a + n + Xslack > (uintptr)Base + Regsize || nchunk == Nchunk)
		return nil;
	brk = a + ((n + 15) & ~15) + Xslack;
	chunk[nchunk].a = a;
	chunk[nchunk].n = brk - a;
	nchunk++;
	return (void*)a;
}

/* xmerge */
static int
bmerge(void *vp, void *vq)
{
	int i, j;
	uintptr p, q;

	p = (uintptr)vp;
	q = (uintptr)vq;
	for(i = 0; i < nchunk; i++)
		if(chunk[i].a == p)
			break;
	for(j = 0; j < nchunk; j++)
		if(chunk[j].a == q)
			break;
	if(i == nchunk || j == nchunk){
		print("bmerge: not mine\n");
		abort();
	}
	if(chunk[i].a + chunk[i].n + Xhdr == chunk[j].a){
		chunk[i].n += Xhdr + chunk[j].n;
		chunk[j] = chunk[--nchunk];
		return 1;
	}
	return 0;
}

/* Pool.move: the block whose data was at from is now at to */
static void
moved(void *from, void *to)
{
	int i, found;
	ulong bsize;
	uchar *f;
	Slot *s;

	f = from;
	bsize = ((ulong*)to)[-1];
	found = 0;
	for(i = 0; i < Nslot; i++){
		s = &slot[i];
		if(s->p != nil && s->p >= f && s->p <= f + bsize - 16){
			s->p = s->p - f + (uchar*)to;
			s->moved = 1;
			found++;
		}
	}
	if(found != 1){
		print("moved: %d slots in one block\n", found);
		abort();
	}
}

static void plock(Pool *p){ USED(p); }
static void pprint(Pool *p, char *fmt, ...){ USED(p); USED(fmt); }
static void
ppanic(Pool *p, char *fmt, ...)
{
	USED(p);
	print("pool panic: %s\n", fmt);
	abort();
}

static ulong
pick(void)
{
	uint k;

	k = rnd() % 100;
	if(k < 2)
		return 0;
	if(k < 70)
		return 1 + rnd() % 256;
	if(k < 95)
		return 1 + rnd() % 4096;
	return 1 + rnd() % (200*1024);
}

static uvlong
off(void *v)
{
	if(v == nil)
		return ~0ULL;
	return (uintptr)v - Base;
}

static void
out(char *op, int i, uvlong a, uvlong b, uvlong c, uvlong d, uvlong r)
{
	mix(op[0]);
	mix(i);
	mix(a);
	mix(b);
	mix(c);
	mix(d);
	mix(r);
	mix(pool.cursize);
	mix(pool.curfree);
	if(trace)
		print("%s %d %lld %lld %lld %lld = %llx; %lld %lld\n", op, i, a, b, c, d, r,
			(uvlong)pool.cursize, (uvlong)pool.curfree);
}

static void
step(void)
{
	Slot *s;
	uint k;
	int i, o;
	ulong n, al, span;
	void *v;

	i = rnd() % Nslot;
	s = &slot[i];
	k = rnd() % 100;
	if(s->p == nil){
		n = pick();
		if(cf->align && k < 25){
			al = aligns[rnd() % nelem(aligns)];
			o = offs[rnd() % nelem(offs)];
			span = spans[rnd() % nelem(spans)];
			if(n == 0)
				span = 0;	/* the C corrupts the pool, see pool.zig */
			v = poolallocalign(&pool, n, al, o, span);
			out("align", i, n, al, (uvlong)(vlong)o, span, off(v));
			s->aligned = 1;
		}else{
			v = poolalloc(&pool, n);
			out("malloc", i, n, 0, 0, 0, off(v));
			s->aligned = 0;
		}
		s->p = v;
		s->n = n;
		s->moved = 0;
		return;
	}
	if(k < 50){
		poolfree(&pool, s->p);
		out("free", i, 0, 0, 0, 0, 0);
		s->p = nil;
	}else if(k < 80 && !cf->compact){
		/*
		 * not with a move hook: when poolrealloc has to allocate and
		 * that compacts the pool, the block it is reallocating moves
		 * under it (in the C and in pool.zig alike)
		 */
		n = pick();
		v = poolrealloc(&pool, s->p, n);
		out("realloc", i, n, 0, 0, 0, off(v));
		if(v != nil){
			s->p = v;
			s->n = n;
			s->aligned = 0;
			s->moved = 0;
		}else if(n == 0)
			s->p = nil;
	}else if(k < 90 && !s->aligned){
		n = poolmsize(&pool, s->p);
		out("size", i, n, 0, 0, 0, 0);
		s->n = n;
	}else if(k < 93 && cf->compact){
		n = poolcompact(&pool);
		out("compact", i, n, 0, 0, 0, 0);
	}else{
		poolfree(&pool, s->p);
		out("free", i, 0, 0, 0, 0, 0);
		s->p = nil;
	}
}

static void
run(Conf *c, uint seed, int nops)
{
	int i;
	void *region;

	region = mapregion(Base, Regsize);
	cf = c;
	memset(slot, 0, sizeof slot);
	nchunk = 0;
	brk = Base;
	ncall = 0;
	rndx = seed * 2654435761U + 1;
	hash = 0xcbf29ce484222325ULL;

	memset(&pool, 0, sizeof pool);
	pool.name = c->name;
	pool.maxsize = c->maxsize;
	pool.minarena = c->minarena;
	pool.quantum = c->quantum;
	pool.minblock = c->minblock;
	pool.alloc = balloc;
	pool.merge = bmerge;
	pool.move = c->compact ? moved : nil;
	pool.flags = c->flags;
	pool.lock = plock;
	pool.unlock = plock;
	pool.print = pprint;
	pool.panic = ppanic;

	for(i = 0; i < nops; i++)
		step();
	poolcheck(&pool);
	print("%s %d %d %016llx %lld %lld\n", c->name, seed, nops, hash,
		(uvlong)pool.cursize, (uvlong)pool.curfree);
	flushout();
	unmapregion(region, Regsize);
}

void
main(int argc, char **argv)
{
	int i, s, nseed, ops;

	if(argc == 4 && strcmp(argv[1], "-t") == 0){
		trace = 1;
		for(i = 0; i < nelem(conf); i++)
			if(strcmp(conf[i].name, argv[2]) == 0)
				run(&conf[i], atoi(argv[3]), envnum("POOLTEST_OPS", conf[i].nops));
		return;
	}
	nseed = envnum("POOLTEST_SEEDS", 3);
	for(i = 0; i < nelem(conf); i++){
		ops = envnum("POOLTEST_OPS", conf[i].nops);
		for(s = 1; s <= nseed; s++)
			run(&conf[i], s, ops);
	}
}
