/*
 * p9test - a small threaded file server on 9front's lib9p, for the
 * parts ramfs and mntgen do not reach: a server without a file tree
 * (walk1 and clone), dirread9p, readstr, the kernel-style command
 * parser, a queue of requests done by a proc of its own (reqqueue),
 * and flush, for comparison with planZ's Zig port
 * (src/user/cmd/p9test.zig, the same server).  Not part of 9front;
 * compiled in the guest by tools/usbzig.rc:
 *	6c -FTVw p9test.c && 6l -o p9test.stock p9test.6
 *
 * usage: p9test [-a] srvname
 *
 * With -a its clients must authenticate (auth9p and the rest of
 * lib9p's auth.c, with factotum).
 *
 * The files: ctl takes "set word", "add a b" and "echo ..."; str
 * reads back what they left; slow answers a read after 200ms and
 * wait after 20 seconds, both from the queue's proc.
 */
#include <u.h>
#include <libc.h>
#include <fcall.h>
#include <thread.h>
#include <auth.h>
#include <9p.h>

enum {
	Qroot,
	Qctl,
	Qstr,
	Qslow,
	Qwait,
	Nfile,
};

char *names[Nfile] = { "/", "ctl", "str", "slow", "wait" };
ulong modes[Nfile] = { DMDIR|0555, 0666, 0444, 0444, 0444 };

enum {
	Cset,
	Cadd,
	Cecho,
};

Cmdtab cmds[] = {
	Cset,	"set",	2,
	Cadd,	"add",	3,
	Cecho,	"echo",	0,
};

char word[64] = "none";
int doauth;
int sum, nclone, nclunk;
Reqqueue *q;

int
dirgen(int i, Dir *d, void*)
{
	i++;
	if(i >= Nfile)
		return -1;
	memset(d, 0, sizeof *d);
	d->qid.path = i;
	d->qid.type = i == Qroot ? QTDIR : 0;
	d->mode = modes[i];
	d->name = estrdup9p(names[i]);
	d->uid = estrdup9p("test");
	d->gid = estrdup9p("test");
	d->muid = estrdup9p("");
	d->length = i == Qstr ? 7 : 0;
	return 0;
}

char*
fswalk1(Fid *fid, char *name, Qid *qid)
{
	int i;

	if(fid->qid.path != Qroot)
		return "not a directory";
	if(strcmp(name, "..") == 0){
		*qid = fid->qid;
		return nil;
	}
	for(i = 1; i < Nfile; i++)
		if(strcmp(name, names[i]) == 0){
			qid->path = i;
			qid->vers = 0;
			qid->type = 0;
			return nil;
		}
	return "no such file";
}

char*
fsclone(Fid*, Fid*)
{
	nclone++;
	return nil;
}

void
fsdestroyfid(Fid *fid)
{
	nclunk++;
	if(doauth)
		authdestroy(fid);
}

void
fsattach(Req *r)
{
	if(doauth && authattach(r) < 0)
		return;
	r->ofcall.qid = (Qid){Qroot, 0, QTDIR};
	r->fid->qid = r->ofcall.qid;
	respond(r, nil);
}

void
fsstat(Req *r)
{
	dirgen((int)r->fid->qid.path - 1, &r->d, nil);
	respond(r, nil);
}

void
slowread(Req *r)
{
	int ms;

	ms = r->fid->qid.path == Qslow ? 200 : 20000;
	if(sleep(ms) < 0)
		respond(r, "interrupted");
	else{
		readstr(r, "slept\n");
		respond(r, nil);
	}
}

void
fsread(Req *r)
{
	char buf[128];

	if(r->fid->qid.type & QTAUTH){
		authread(r);
		return;
	}
	switch((int)r->fid->qid.path){
	case Qroot:
		dirread9p(r, dirgen, nil);
		respond(r, nil);
		break;
	case Qstr:
		snprint(buf, sizeof buf, "word %s sum %d\n", word, sum);
		readstr(r, buf);
		respond(r, nil);
		break;
	case Qslow:
	case Qwait:
		reqqueuepush(q, r, slowread);
		break;
	default:
		respond(r, "nothing to read");
	}
}

void
fswrite(Req *r)
{
	Cmdbuf *cb;
	Cmdtab *ct;

	if(r->fid->qid.type & QTAUTH){
		authwrite(r);
		return;
	}
	if(r->fid->qid.path != Qctl){
		respond(r, "not the ctl file");
		return;
	}
	cb = parsecmd(r->ifcall.data, r->ifcall.count);
	ct = lookupcmd(cb, cmds, nelem(cmds));
	if(ct == nil){
		respondcmderror(r, cb, "%r");
		free(cb);
		return;
	}
	switch(ct->index){
	case Cset:
		snprint(word, sizeof word, "%s", cb->f[1]);
		break;
	case Cadd:
		sum += atoi(cb->f[1]) + atoi(cb->f[2]);
		break;
	case Cecho:
		if(cb->nf > 3){
			respondcmderror(r, cb, "too many words (%d)", cb->nf);
			free(cb);
			return;
		}
		break;
	}
	free(cb);
	r->ofcall.count = r->ifcall.count;
	respond(r, nil);
}

void
fsflush(Req *r)
{
	reqqueueflush(q, r->oldreq);
	respond(r, nil);
}

void
fsend(Srv*)
{
	threadexitsall(nil);
}

Srv fs = {
	.attach = fsattach,
	.walk1 = fswalk1,
	.clone = fsclone,
	.destroyfid = fsdestroyfid,
	.stat = fsstat,
	.read = fsread,
	.write = fswrite,
	.flush = fsflush,
	.end = fsend,
};

int mainstacksize = 32*1024;

void
threadmain(int argc, char **argv)
{
	if(argc == 3 && strcmp(argv[1], "-a") == 0){
		doauth = 1;
		fs.auth = auth9p;
		argv++;
		argc--;
	}
	if(argc != 2)
		sysfatal("usage: p9test [-a] srvname");
	q = reqqueuecreate();
	threadpostmountsrv(&fs, argv[1], nil, 0);
	threadexits(nil);
}
