implement Jobgen, Simplegen, Taskgenerator;
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Context: import sh;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "indexes.m";
	indexes: Indexes;
	Index: import indexes;
include "keyring.m";
	keyring: Keyring;
include "bundle.m";
	bundle: Bundle;
include "readdir.m";
	readdir: Readdir;
include "attributes.m";
include "taskgenerator.m";
include "tggeneric.m";
	tggeneric: TGgeneric;
	Task: import TGgeneric;

Jobgen: module {};

# job specification:

#(job
#	(file
#		(path path)
#		(name name)
#		(size size)
#		(kind kind)
#		(split how)
#	)
#	(value tag [val...])
#		where val can be:
#		(range [from] to [by])
#		(for a b c d...)
#	(task [arg...])
#	(output kind)
#	(script name [arg...])
#)

# e.g.
#(job
#	(file (path /tmp/x) (split lines) (kind stdin))
#	(file (path /tmp/y))
#	(task test "{echo hello; md5sum}")
#)

Static, Lines, Records, Files: con iota;

Record: adt {
	kind: int;
	skiprec: fn(r: self ref Record, iob: ref Iobuf): int;
};

Record.skiprec(nil: self ref Record, iob: ref Iobuf): int
{
	return iob.gets('\n') != nil;
}

Param: adt {
	mk: fn(p: self ref Param, restoring: int): (ref TGgeneric->Param, ref Iterator, string);

	name: string;
	pick{
	File =>
		path: string;
		size: big;
		kind: string;
		split: int;
	Value =>
		v: list of ref Sexp;
	}
};

Job: adt {
	params: list of ref Param;
	outkind: string;
	taskargs: list of string;
	script: list of string;
};

Iterator: adt {
	getval: fn(i: self ref Iterator, n: int): string;
	name: string;
	lim: int;
	pick {
	File =>
		index: ref Index;
		fd: ref Sys->FD;
		f: ref Param.File;
	Dir =>
		path: string;
		files: array of ref Sys->Dir;
		kind: string;
	Range =>
		start, mul: int;
	Enum =>
		vals: array of string;
#	Eval =>
#		cmd: ref Sh->Cmd;
	}
};

maxretries := 10;
BIG: con ~(big 1<<63);
blankjob: Job;

currtask: ref Task;
currtaskid := -1;
currtasksize: big;

maxindex := 0;
maxoutid := 0;
maxtaskid: int;
ntasks := 1;
iters: array of ref Iterator;
job: ref Job;
staticparams: list of ref TGgeneric->Param;
staticsize := big 0;
outmode := Sys->ORDWR;
shctxt: ref Context;

init(root, nil, state: string, nil: chan of int, args: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	keyring = load Keyring Keyring->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return (nil, sys->sprint("cannot load %q: %r", Bufio->PATH));
	bufio->sopen(nil);
	sh = load Sh Sh->PATH;
	if(sh == nil)
		return (nil, sys->sprint("cannot load %q: %r", Sh->PATH));
	sh->initialise();
	sexprs = load Sexprs Sexprs->PATH;
	if(sexprs == nil)
		return (nil, sys->sprint("cannot load %q: %r", Sexprs->PATH));
	sexprs->init();
	readdir = load Readdir  Readdir->PATH;
	if(readdir == nil)
		return (nil, sys->sprint("cannot load %q: %r", Readdir->PATH));
	bundle = load Bundle  Bundle->PATH;
	if(bundle == nil)
		return (nil, sys->sprint("cannot load %q: %r", Bundle->PATH));
	bundle->init();
	indexes = load Indexes Indexes->PATH;
	if(indexes == nil)
		return (nil, sys->sprint("cannot load %q: %r", Indexes->PATH));
	indexes->init();
	tggeneric = load TGgeneric TGgeneric->PATH;
	if(tggeneric == nil)
		return (nil, sys->sprint("cannot load %q: %r", TGgeneric->PATH));
	if((err := tggeneric->init()) != nil)
		return (nil, err);
	# usage: job taskfile [staticfile...]
	if(len args != 2)
		return (nil, "usage: job spec-sexpr");
	(job, err) = parsespec(hd tl args);
	if(job == nil)
		return (nil, "bad spec: "+err);
	if(job.script != nil){
		shctxt = Context.new(nil);
		shctxt.set("root", ref Sh->Listnode(nil, root) :: nil);
		shctxt.set("fn-verify", nil);
		shctxt.set("fn-finalise", nil);
		shctxt.set("fn-complete", nil);

		{
			shctxt.run(sh->stringlist2list(
				"run" :: root+"/"+hd job.script+".jobscript"::tl job.script), 0);
		}exception e{
		"fail:*" =>
			return (nil, "script error: "+e[5:]);
		}
	}
	if(job.taskargs == nil)
		return (nil, "no task specified");
	if(state != nil){
		(n, toks) := sys->tokenize(state, " ");
		if(n != 2)
			return (nil, sys->sprint("bad state %#q", state));
		maxtaskid = int hd toks;
		maxoutid = int hd tl toks;
	}
	if(job.outkind == "bundle")
		outmode |= Sys->ORCLOSE;
	iterl: list of ref Iterator;
	for(pl := job.params; pl != nil; pl = tl pl){
		(p, it, e) := (hd pl).mk(state != nil);
		if(p != nil){
			staticparams = p :: staticparams;
			pick f := p {
			File =>
				staticsize += f.size;
			}
		}else if(it != nil){
			if(it.lim <= 0)
				return (nil, "bad number of tasks");
			if((ntasks *= it.lim) < 0)		# check for overflow
				return (nil, "too many tasks");
			iterl = it :: iterl;
		}else
			return (nil, e);
	}
	iters = array[len iterl] of ref Iterator;
	for(i := len iters; iterl != nil; iterl = tl iterl)
		iters[--i] = hd iterl;
	return (tggeneric->start(load Simplegen "$self"), nil);
}

Param.mk(gp: self ref Param, restoring: int): (ref TGgeneric->Param, ref Iterator, string)
{
	err: string;
	pick p := gp {
	Value =>
		v := p.v;
		if(v == nil || !(hd v).islist())
			return (ref (TGgeneric->Param).Value(p.name, stringlist(v)), nil, nil);
		case (hd v).op() {
		"range" =>
			args := (hd v).args();
			it := ref Iterator.Range(p.name, 0, 0, 1);
			for(a := args; a != nil; a = tl a)
				if((hd a).islist())
					return (nil, nil, "bad args to range");
			case len args {
			1 =>			# end
				it.lim = int (hd args).astext();
			2 =>			# start end
				it.start = int (hd args).astext();
				it.lim = int (hd tl args).astext() - it.start;
			3 =>			# start end step
				it.start = int (hd args).astext();
				e := int (hd tl args).astext();
				it.mul = int (hd tl tl args).astext();
				if(it.mul == 0)
					return (nil, nil, "zero step size in range");
				it.lim = (e - it.start) / it.mul;
			* =>
				return (nil, nil, "too many args to range");
			}
			if(it.lim <= 0)
				return (nil, nil, "bad values in range");
			return (nil, it, nil);
		"for" =>
			args := (hd v).args();
			if(args == nil)
				return (nil, nil, "no values for enumeration");
			vals := array[len args] of string;
			for(i := 0; args != nil; args = tl args)
				vals[i++] = (hd args).astext();
			return (nil, ref Iterator.Enum(p.name, len vals, vals), nil);
		* =>
			return (nil, nil, "unknown value iterator: "+(hd v).op());
		}
	File =>
		case p.split {
		Files =>
			it := ref Iterator.Dir;
			(d, n) := readdir->init(p.path, Readdir->NAME|Readdir->COMPACT);
			if(n == -1)
				return (nil, nil, sys->sprint("error reading %q: %r", p.path));
			if(n == 0)
				return (nil, nil, sys->sprint("no files in %q", p.path));
			iname := "dindex"+string maxindex++;
			it.name = p.name;
			it.files = d;
			it.path = p.path;
			it.kind = p.kind;
			it.lim = len d;
			if(restoring){
				if(int readfile(iname) != len d)
					return (nil, nil, sys->sprint("file count has changed in %q", p.path));
			}else{
				if((fd := sys->create(iname, Sys->OWRITE, 8r666)) == nil)
					return (nil, nil, sys->sprint("cannot create %q: %r", iname));
				sys->fprint(fd, "%d\n", len d);
			}
			return (nil, it, nil);
		Lines or
		Records =>
			it := ref Iterator.File;
			it.name = p.name;
			it.f = p;
			if((it.fd = sys->open(p.path, Sys->OREAD)) == nil)
				return (nil, nil, sys->sprint("cannot open %q: %r", p.path));
			iname := "index"+string maxindex++;
			if(restoring){
				(it.index, err) = Index.open(iname, p.path);
				if(it.index == nil)
					return (nil, nil, "index "+iname+": "+err);
			}else{
				if(p.split == Records)
					return (nil, nil, "record split unimplemented");
				rec := ref Record(p.split);
				(it.index, err) = Index.create(iname, p.path, rec);
				if(it.index == nil)
					return (nil, nil, err);
			}
			it.lim = it.index.nrecs;
			return (nil, it, nil);
		Static =>
			f := ref (TGgeneric->Param).File(p.name, nil, p.size, p.kind, nil, big 0, BIG);
			f.fd = sys->open(p.path, Sys->OREAD);
			if(f.fd == nil)
				return (nil, nil, sys->sprint("cannot open %q: %r", p.path));
			(ok, stat) := sys->fstat(f.fd);
			if(ok == -1)
				return (nil, nil, sys->sprint("cannot stat %q: %r", p.path));
			if(p.kind == nil && (stat.mode & Sys->DMDIR) != 0)
				p.kind = "bundle";
			if(p.kind == "bundle" && (stat.mode & Sys->DMDIR) != 0){
				bpath := "./b."+p.name;
				if(restoring){
					f.fd = sys->open(bpath, Sys->OREAD);
					if(f.fd == nil)
						return (nil, nil, sys->sprint("cannot open %q: %r", bpath));
				}else{
					f.fd = sys->create(bpath, Sys->ORDWR, 8r666);
					if(f.fd == nil)
						return (nil, nil, sys->sprint("cannot create %q: %r", bpath));
					if((err = bundle->bundle(p.path, f.fd)) != nil)
						return (nil, nil, sys->sprint("bundle %q failed: %s", p.path, err));
					sys->seek(f.fd, big 0, Sys->SEEKSTART);
				}
				(nil, stat) = sys->fstat(f.fd);
			}
			if(f.size < stat.length)
				f.size = stat.length;
			f.hash = tggeneric->hash(f.fd, big 0, BIG);	# XXX could save this to reduce time taken restoring
			return (f, nil, nil);
		* =>
			return (nil, nil, "unknown split type");
		}
	}
}

parsespec(s: string): (ref Job, string)
{
	(se, nil, err) := Sexp.parse(s);
	if(se == nil)
		return (nil, err);
	if(!se.islist() || se.op() != "job")
		return (nil, "expected (job...)");

	j := ref blankjob;
	j.outkind = "data";
	for(els := se.args(); els != nil; els = tl els){
		(op, args) := ((hd els).op(), (hd els).args());
		case op {
		"file" =>
			(f, e) := parsefile(args);
			if(f == nil)
				return (nil, e);
			j.params = f :: j.params;
		"value" =>
			if(args == nil || (hd args).islist())
				return (nil, "no tag for value");
			j.params = ref Param.Value((hd args).astext(), tl args) :: j.params;
		"task" =>
			j.taskargs = stringlist(args);
		"output" =>
			if(len args != 1)
				return (nil, "\"output\" needs one field only");
			j.outkind = (hd args).astext();
		"script" =>
			j.script = stringlist(args);
			if(j.script == nil)
				return (nil, "script file not given");
			p := hd j.script;
			for(i := 0; i < len p; i++)
				if(p[i] == '/')
					return (nil, "script name cannot contain '/'");
		* =>
			return (nil, sys->sprint("unknown job element %q", op));
		}
	}
	return (j, nil);
}

stringlist(els: list of ref Sexp): list of string
{
	r, args: list of string;
	for(; els != nil; els = tl els){
		if((hd els).islist())
			return nil;
		args = (hd els).astext() :: args;
	}
	for(; args != nil; args = tl args)
		r = hd args :: r;
	return r;
}

parsefile(els: list of ref Sexp): (ref Param.File, string)
{
	f := ref Param.File(nil, nil, big 0, "data", Static);
	for(; els != nil; els = tl els){
		if((hd els).islist() == 0)
			return (nil, "bad filename element "+(hd els).text());
		(op, args) := ((hd els).op(), (hd els).args());
		if(len args != 1 || (hd args).islist())
			return (nil, "bad filename element "+(hd els).text());
		arg := (hd args).astext();
		case op {
		"name" =>
			f.name = arg;
		"size" =>
			f.size = big arg;
		"kind" =>
			f.kind = arg;
		"split" =>
			case arg {
			"lines" =>
				f.split = Lines;
			"records" =>
				f.split = Records;
			"files" =>
				f.split = Files;
			* =>
				return (nil, "unknown split type "+arg);
			}
		"path" =>
			f.path = arg;
		}
	}
	if(f.path == nil)
		return (nil, "no path for file");
	if(f.name == nil)
		f.name = filename(f.path);
	return (f, nil);
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
	return ntasks;
}

start(id: string, tries: int, spec: ref Clientspec): (int, ref TGgeneric->Task, string)
{
	if(tries >= maxretries)
		return (Nomore, nil, "too many tries");

	if(id == nil && maxtaskid >= ntasks)
		return (Nomore, nil, nil);

	# cache the most recent new task created, on the assumption
	# that the scheduler runs through many clients at a time, trying a task
	# on each one.
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
	task.out = sys->create(task.instid, outmode, 8r666);
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
	a := iterators(n);
	size := staticsize;
	params := staticparams;
	for(i := 0; i < len a; i++){
		p: ref TGgeneric->Param;
		pick it := iters[i] {
		File =>
			soff := it.index.offsetof(a[i]);
			eoff := it.index.offsetof(a[i]+1);
			f := ref (TGgeneric->Param).File(it.name, nil, eoff-soff, it.f.kind, it.fd, soff, eoff);
			f.hash = tggeneric->hash(it.fd, soff, eoff);	# XXX could have index store hash too.
			size += eoff - soff;
			p = f;
		Dir =>
			f := ref (TGgeneric->Param).File(it.name, nil, it.files[a[i]].length, it.kind, sys->open(it.path+"/"+it.files[a[i]].name, Sys->OREAD), big 0, BIG);
			if(f.fd == nil)
				log(sys->sprint("cannot open %q: %r", it.path+"/"+it.files[a[i]].name));
			f.hash = tggeneric->hash(f.fd, big 0, BIG);
			# XXX what about subdirectories? if kind is bundle, we should
			# bundle up the contents, but what do we call the bundle file?
			# i guess we could create the bundle file, and delete it when the
			# task gets finalised.
			p = f;
		* =>
			p = ref (TGgeneric->Param).Value(it.name, it.getval(a[i]) :: nil);
		}
		params = p :: params;
	}
	return (ref Task(string n, nil, job.taskargs, params, nil, job.outkind, nil), size);
}

reconnect(id: string): (ref Task, string)
{
	outname := sys->sprint("%d.%d", int id, maxoutid++);
	outfd := sys->create(outname, outmode, 8r666);
	if(outfd == nil)
		return (nil, sys->sprint("cannot create %s: %r", outname));
	return (ref Task(id, outname, nil, nil, outfd, job.outkind, outname+".err"), nil);
}

Iterator.getval(i: self ref Iterator, n: int): string
{
	pick it := i {
	Range =>
		return string (it.start + it.mul * n);
	Enum =>
		return it.vals[n];
	* =>
		return "unknown";
	}
}

iterators(id: int): array of int
{
	a := array[len iters] of int;
	for(i := 0; i < len a; i++){
		lim := iters[i].lim;
		a[i] = id % lim;
		id /= lim;
	}
	return a;
}

verify(t: ref TGgeneric->Task, nil: big): string
{
	f := t.instid;
	if(t.outkind == "bundle"){
		sys->seek(t.out, big 0, Sys->SEEKSTART);
		f = t.instid+".d";
		err := bundle->unbundle(t.out, f);
		t.out = nil;
		if(err != nil)
			return "cannot unpack: "+err;
		t.out = nil;
		remove(t.instid);
	}
	if(shctxt == nil || (vfn := shctxt.get("fn-verify")) == nil || (hd vfn).cmd == nil)
		return nil;
	ctxt := shctxt.copy(1);

	{
		return ctxt.run(hd vfn :: ref Sh->Listnode(nil, f) :: nil, 0);
	} exception e {
	"fail:*" =>
		return e[5:];
	}
}

finalise(t: ref TGgeneric->Task, ok: int)
{
	t.out = nil;
	d := sys->nulldir;
	if(ok){
		d.name = t.id;
		if(t.outkind == "bundle"){
			remove(t.instid);
			if(sys->wstat(t.instid+".d", d) == -1)
				log(sys->sprint("wstat %s failed: %r", t.instid+".d"));
		}else{
			if(sys->wstat(t.instid, d) == -1)
				log(sys->sprint("wstat %s failed: %r", t.instid));
		}
		# error file will only exist if some errors have been generated.
		d.name = t.id + ".err";
		sys->remove(d.name);		# remove error file from previous uncompleted task.
		sys->wstat(t.errfile, d);

		if(shctxt != nil && (ffn := shctxt.get("fn-finalise")) != nil && (hd ffn).cmd != nil){
			ctxt := shctxt.copy(1);
			ctxt.set("taskid", ref Sh->Listnode(nil, t.id) :: nil);
			{
				ctxt.run(hd ffn :: ref Sh->Listnode(nil, t.id) :: nil, 0);
			}exception{
			"fail:*" =>
				;
			}
		}	
	}else{
		sys->remove(t.instid);
		if(t.outkind == "bundle")
			remove(t.instid+".d");
		# keep at least one instance of the diagnostics from a failed task.
		d.name = t.id + ".err";
		if(sys->stat(t.errfile).t0 != -1){
			if(sys->wstat(t.errfile, d) == -1)
				sys->remove(t.errfile);
		}
	}
}

complete()
{
#	if(shctxt != nil && shctxt.get("fn-complete") != nil)
}

quit()
{
#	init(nil, nil, nil, nil); ????? XXX what was this meant to be doing?
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

readfile(f: string): string
{
	buf := array[8192] of byte;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}
