# how to deal with problem of having lots of output, but avoiding
# the task generator having to check it all for validity?
# could have "validity servers" - a worker can go to one of these
# and have its result verified and signed. it can then give
# the task generator the signed results (doesn't actually need
# the results - could just provide the signed hash, which the
# task generator could get from somewhere else at a convenient time).
# 
# alternatively, if we're prepared to trust the client to do the checking (hmm)
# then we should provide a way for the client to submit error messages
# as the result.
# 
# log all diagnostic messages from a job in $workdir/log.
# this should then be accessible through /n/remote/admin/N/log
# (is it blocking??)
# 
# taskgenerator to do admin on clients
# 	- software installation
# 	- parameter modification (?)
# 	- logfile retrieval.
# 	- active status probing.

implement Goldgen, Simplegen, Taskgenerator;
include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "readdir.m";
	readdir: Readdir;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "indexes.m";
	indexes: Indexes;
	Index: import indexes;
include "attributes.m";
include "taskgenerator.m";
include "bundle.m";
	bundle: Bundle;
include "tggeneric.m";
	tggeneric: TGgeneric;
	Task, Param: import TGgeneric;

Goldgen: module {};

Record: adt {
	skiprec: fn(r: self ref Record, iob: ref Iobuf): int;
};

BIG: con 16rfffffffffff;

maxretries := 10;

maxoutid := 0;
maxtaskid: int;

currtask: ref Task;
currtaskid := -1;
currtasksize: big;

staticfiles: list of ref Param.File;
staticsize := big 0;

index: ref Index;
ligfd: ref Sys->FD;
nligs: int;

init(nil, nil, state: string, nil: chan of int, args: list of string): (chan of ref Taskgenreq, string)
{
	{
		return init0(state, args);
	} exception e {
	"fail:*" =>
		return (nil, e[5:]);
	}
}

init0(state: string, args: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->sopen(nil);
	readdir = load Readdir Readdir->PATH;
	if (readdir == nil)
		return (nil, sys->sprint("cannot load %q: %r", Readdir->PATH));
	indexes = load Indexes Indexes->PATH;
	if(indexes == nil)
		return (nil, sys->sprint("cannot load %q: %r", Indexes->PATH));
	indexes->init();
	tggeneric = load TGgeneric TGgeneric->PATH;
	if(tggeneric == nil)
		return (nil, sys->sprint("cannot load %q: %r", TGgeneric->PATH));
	if((err := tggeneric->init()) != nil)
		return (nil, err);
	bundle = load Bundle Bundle->PATH;
	if(bundle == nil)
		return (nil, sys->sprint("cannot load %q: %r", Bundle->PATH));
	bundle->init();

	if(len args < 5)
		return (nil, "usage: gold ligandspertask ligandfile conffile proteinfile [otherfiles...]");
	args = tl args;
	(nligs, args) = (int hd args, tl args);
	if(nligs < 1)
		return (nil, "bad number of ligands per task");
	ligf: string;
	(ligf, args) = (hd args, tl args);
	if(state == nil){
		rec: ref Record;
		(index, err) = Index.create("index", ligf, rec);
		if(index == nil)
			return (nil, err);
	}else{
		(n, toks) := sys->tokenize(state, " ");
		if(n != 2)
			return (nil, sys->sprint("bad state %#q", state));
		maxtaskid = int hd toks;
		maxoutid = int hd tl toks;
		(index, err) = Index.open("index", ligf);
		if(index == nil)
			return (nil, err);
	}
	ligfd = sys->open(ligf, Sys->OREAD);
	if(ligfd == nil)
		return (nil, sys->sprint("cannot open %q: %r", ligf));

	addfile(hd args, "gold.conf", "data");
	args = tl args;

	addfile(hd args, "protein.pdb", "data");
	args = tl args;

	for(; args != nil; args = tl args)
		addfile(hd args, nil, "data");
	bundleauxfiles();
	addfile("auxfiles.bun", "auxfiles", "bundle");

	for(fl := staticfiles; fl != nil; fl = tl fl)
		staticsize += (hd fl).size;

	return (tggeneric->start(load Simplegen "$self"), nil);
}

bundleauxfiles()
{
	fd := sys->create("auxfiles.bun", Sys->OWRITE, 8r666);
	if(fd == nil)
		raise sys->sprint("fail:cannot create auxfiles.bun: %r");
	err := bundle->bundle("/grid/master/gold/auxfiles", fd);
	if(err != nil)
		raise "fail:"+err;
}

filename(f: string): string
{
	for(i := len f - 1; i >= 0; i--)
		if(f[i] == '/')
			return f[i+1:];
	return f;
}

state(): string
{
	return sys->sprint("%d %d", maxtaskid, maxoutid);
}

taskcount(): int
{
	return index.nrecs / nligs;
}

checkspec(nil: ref Clientspec): string
{
	return nil;
}

start(id: string, tries: int, spec: ref Clientspec): (int, ref TGgeneric->Task, string)
{
	if(tries >= maxretries)
		return (Nomore, nil, "too many tries");
	if(id == nil && maxtaskid >= index.nrecs / nligs)
		return (Nomore, nil, nil);
	if(id == nil)
		n := int maxtaskid;
	else
		n = int id;

	if(currtask != nil && currtaskid == n)
		(task, size) := (currtask, currtasksize);
	else{
		(task, size) = (currtask, currtasksize) = mktask(n);
		currtaskid = n;
	}

	if((err := tggeneric->checkspec(spec, hd task.taskargs, size)) != nil)
		return (Error, nil, err);

	task.instid = sys->sprint("%d.%d", n, maxoutid++);
	task.out = sys->create(task.instid, Sys->ORDWR|Sys->ORCLOSE, 8r666);
	if(task.out == nil)
		return (Error, nil, sys->sprint("cannot create %s: %r", task.instid));
	task.errfile = task.instid+".err";
	if(id == nil)
		maxtaskid++;
	currtask = nil;
	return (Started, task, nil);
}

mktask(n: int): (ref Task, big)
{
	soff := index.offsetof(n*nligs);
	eoff := index.offsetof((n+1)*nligs);

	td := ref Param.File("ligands.sdf", tggeneric->hash(ligfd, soff, eoff), eoff-soff, "data", ligfd, soff, eoff);
	return (ref Task(string n, nil, "gold"::nil, td :: staticfiles, nil, "bundle", nil), staticsize+(eoff-soff));
}

reconnect(id: string): (ref Task, string)
{
	outname := sys->sprint("%d.%d", int id, maxoutid++);
	outfd := sys->create(outname, Sys->ORDWR|Sys->ORCLOSE, 8r666);
	if(outfd == nil)
		return (nil, sys->sprint("cannot create %s: %r", outname));
	return (ref Task(id, outname, nil, nil, outfd, "bundle", nil), nil);
}

verify(t: ref TGgeneric->Task, nil: big): string
{
	sys->seek(t.out, big 0, Sys->SEEKSTART);
	d := t.instid+".d";
	err := bundle->unbundle(t.out, d);
	t.out = nil;
	if(err != nil)
		return "cannot unpack: "+err;
	t.out = nil;
	remove(t.instid);
	if(sys->stat(d+"/error").t0 != -1)
		return "client-side error: "+readfile(d+"/error", 1);

	logf := bufio->open(d+"/gold.log", Sys->OREAD);
	if(logf == nil){
		if((errs := bufio->open(d+"/gold.err", Sys->OREAD)) != nil){
			while((s := errs.gets('\n')) != nil)
				log(sys->sprint("task gold-error %q %q", t.id, stripnl(s)));
		}
		return "no log file found";
	}
	while((s := logf.gets('\n')) != nil){
		if(prefix(s, "Total run time")){
			(n, toks) := sys->tokenize(s, " \t\n");
			if(n != 10)
				return "bad run time line";
			tm := int hd tl tl tl tl tl toks;
			if(tm < 10)
				return "run time too fast ("+string tm+" seconds), line "+s[0:len s - 1];
			break;
		}
	}
	return nil;
}

stripnl(s: string): string
{
	for(i := len s - 1; i >= 0; i--)
		if(s[i] != '\n' && s[i] != '\r')
			break;
	return s[0:i+1];
}

readfile(f: string, stripnl: int): string
{
	buf := array[8192] of byte;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	if(stripnl && buf[n - 1] == byte '\n')
		n--;
	return string buf[0:n];
}

prefix(s, p: string): int
{
	return len s >= len p && s[0] == p[0] && s[0:len p] == p;
}

finalise(t: ref TGgeneric->Task, ok: int)
{
	t.out = nil;
	remove(t.instid);
	if(ok){
		d := Sys->nulldir;
		d.name = t.id;
		if(sys->wstat(t.instid+".d", d) == -1)
			log(sys->sprint("cannot rename task directory %q to %q: %r", t.instid+".d", d.name));
	}else{
		d := Sys->nulldir;
		d.name = t.instid+".failed";
		if(sys->wstat(t.instid+".d", d) == -1)
			log(sys->sprint("cannot rename task directory %q to %q: %r", t.instid+".d", d.name));
	}
}

complete()
{
	remove("auxfiles.bun");
	remove("index");
}

quit()
{
}

opendata(
	nil: string,
	nil: int,
	nil:		chan of Taskgenerator->Readreq,
	nil:	chan of Taskgenerator->Writereq,
	nil:	chan of int): string
{
	return "nope";
}

addfile(path, name, kind: string)
{
	if(name == nil)
		name = filename(path);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		raise sys->sprint("fail:cannot open %q: %r", path);
	(ok, stat) := sys->fstat(fd);
	if(ok == -1)
		raise sys->sprint("fail:cannot stat %q: %r", path);
	f := ref Param.File(name, nil, stat.length, kind, fd, big 0, BIG);
	f.hash = tggeneric->hash(f.fd, big 0, BIG);
	staticfiles = f :: staticfiles;
}

Record.skiprec(nil: self ref Record, iob: ref Iobuf): int
{
	SEP1: con "$$$$\n";
	SEP2: con "$$$$\r\n";

	reclen := 0;
	for (;;) {
		line := iob.gets('\n');
		if (line == nil)
			break;
		if (line[0] == '$'  && (line == SEP1 || line == SEP2) && reclen)
			break;
		reclen++;
	}
	return reclen != 0;
}

remove(path: string): int
{
	(ok, stat) := sys->stat(path);
	if(ok == -1)
		return 0;
	return remove0(path, stat.mode & Sys->DMDIR);
}

remove0(path: string, isdir: int): int
{
	if(isdir == 0){
		if(sys->remove(path) == -1){
			log(sys->sprint("cannot remove %q: %r", path));
			return -1;
		}
		return 0;
	}
	(d, n) := readdir->init(path, Readdir->NONE|Readdir->COMPACT);
	r := 0;
	for(i := 0; i < n; i++)
		if(remove0(path + "/" + d[i].name, d[i].mode & Sys->DMDIR) == -1)
			r = -1;
	if(r != -1 && sys->remove(path) == -1){
		log(sys->sprint("cannot remove %q: %r", path));
		r = -1;
	}
	return r;
}

log(e: string)
{
	sys->print("%s\n", e);
}
