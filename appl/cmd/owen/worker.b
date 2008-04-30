implement Worker;
include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "sh.m";
	sh: Sh;
	Context: import sh;
include "arg.m";
include "readdir.m";
	readdir: Readdir;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "rand.m";
	rand: Rand;
include "bundle.m";
	bundle: Bundle;
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "tables.m";
	tables: Tables;
	Strhash: import tables;
include "mount.m";
	mount: Mount;
include "hostattrs.m";

Worker: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# to do:
# - guard against broken processes - restart if we find any.
# - do software update better - perhaps have complete separate copy of
#	installation tree, and switch to that.
# - posix shell script to start worker (and restart when emu exits)

Task: adt {
	srvid: string;
	argv: list of string;
	workid: int;
	exclusive: int;
	deadline: int;		# absolute time of deadline (in seconds since startup time).
	done: int;
	reqspace: big;
	files: list of ref File;
	values: list of (string, list of string);
	outkind: string;

	readnew: fn(fd: ref Sys->FD): (ref Task, string);
	save: fn(t: self ref Task);
	restore: fn(workid: int): ref Task;
	finish: fn(t: self ref Task);
	workdir: fn(t: self ref Task): string;
	clientid: fn(t: self ref Task): string;
	getspace: fn(t: self ref Task): (int, list of ref File);
};

File: adt {
	key: string;
	hash: array of byte;
	path: string;
	name: string;
	size: big;
	kind: string;
	refcount: int;
	fetched: int;
	fetchlock: chan of int;
	next, prev: cyclic ref File;		# LRU
	details: ref Sexp;

	parse: fn(se: ref Sexp): (ref File, string);
	restore: fn(dir: string): (ref File, string);
	use: fn(f: self ref File);
	remove: fn(f: self ref File): int;
	fetch: fn(f: self ref File, fd: ref Sys->FD): string;
};

used: ref File;
files: ref Strhash[ref File];

Blanktask: con Task(nil, nil, -1, -1, -1, 0, big 0, nil, nil, nil);
blankfile: File;

SCHEDDIR:	con "/n/remote";
MAXBACKOFF: con 5 * 60 * 1000;
POLL: con 30 * 60 * 1000;
ATTRCHECK: con 60 * 60 * 1000;
ncpu := 1;
Maxname: con 27;
cachesize := big (1024 * 1024 * 1024);		# use max of 1GB space by default.
maxfiles := 5;

root := "/grid/slave";
workdir := "";
verbose := 1;
noauth := 0;
schedid := "";
keyfile := "";
nodeattrs: Attrs[string];
versionattrs: Attrs[string];
currattrs: Attrs[string];

stopc: array of chan of string;			# [ncpu]
tasklock: chan of int;					# [1]
worktoken: chan of int;				# [ncpu]
down: chan of (ref Task, int);
attrcheck: chan of int;				# [1]

spacelock: chan of int;
currused := big 0;						# space in use by currently running tasks.
actused := big 0;						# total disk space in use.
nfiles := 0;

devnull: ref Sys->FD;
timefd: ref Sys->FD;
starttime: int;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKNS, nil);

	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		badmodule(Keyring->PATH);

	sh = load Sh Sh->PATH;
	if (sh == nil)
		badmodule(Sh->PATH);
	sh->initialise();

	rand = load Rand Rand->PATH;
	if (rand == nil)
		badmodule(Rand->PATH);
	rand->init(sys->millisec());

	readdir = load Readdir Readdir->PATH;
	if (readdir == nil)
		badmodule(Readdir->PATH);

	str = load String String->PATH;
	if (str == nil)
		badmodule(String->PATH);

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		badmodule(Bufio->PATH);

	bundle = load Bundle Bundle->PATH;
	if(bundle == nil)
		badmodule(Bundle->PATH);
	bundle->init();

	attributes = load Attributes Attributes->PATH;
	if(attributes == nil)
		badmodule(Attributes->PATH);

	sexprs = load Sexprs Sexprs->PATH;
	if(sexprs == nil)
		badmodule(Sexprs->PATH);
	sexprs->init();

	tables = load Tables Tables->PATH;
	if(tables == nil)
		badmodule(Tables->PATH);

	mount = load Mount Mount->PATH;
	if(mount == nil)
		badmodule(Mount->PATH);
	mount->init();

	hostattrs := load Hostattrs Hostattrs->PATH;
	if(hostattrs == nil)
		badmodule(Hostattrs->PATH);
	hostattrs->init();
	nodeattrs = hostattrs->getattrs();
	if((v := nodeattrs.get("cputype")) != nil){
		toks := str->unquoted(v);
		if(len toks > 2 && int hd tl tl toks > 0)
			ncpu = int hd tl tl toks;
	}
	hostattrs = nil;

	procname := "";
	addr := "";

	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("worker [-s schedaddr] [configfile]");
	while((opt := arg->opt()) != 0){
		case opt {
		'a' =>
			addr = arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(len argv > 1)
		arg->usage();
	arg = nil;

	cfg: ref Iobuf;
	if(argv != nil){
		if((cfg = bufio->open(relpath(hd argv, "/grid/slave"), Sys->OREAD)) == nil){
			logerror(sys->sprint("cannot open %q: %r", relpath(hd argv, "/grid/master")));
			raise "fail:error";
		}
	}else
		cfg = bufio->open("/grid/slave/config", Sys->OREAD);
	if(cfg != nil){
		while(((se, err) := Sexp.read(cfg)).t0 != nil){
			attr := se.op();
			args := se.args();
			if(len args != 1){
				logerror(sys->sprint("invalid config line %s", se.text()));
				continue;
			}
			val := (hd args).astext();
			case attr {
			"root" =>
				root = val;
			"schedaddr" =>
				addr = val;
			"workdir" =>
				workdir = val;
			"nproc" =>
				ncpu = int val;
			"auth" =>
				if(val == "0")
					noauth = 1;
			"workerkey" or
			"workerkeyfile" =>
				keyfile = val;
			"schedid" =>
				schedid = val;
			"procname" =>
				procname = val;
			"cachesize" =>
				c := units(val);
				if(c == big -1)
					logerror(sys->sprint("bad value for cachesize %q", val));
				else
					cachesize = c;
			"verbose" =>
				verbose = int val;
			}
		}
		if(err != nil){
			logerror(sys->sprint("config file error: %s", err));
			raise "fail:config error";
		}
	}
	if(addr == nil){
		addr = readfile(root+"/schedaddr", 1);
		if(addr == nil){
			logerror("no scheduler address found");
			raise "fail:no scheduler address";
		}
		if(addr[len addr - 1] == '\r')
			addr = addr[0:len addr - 1];
	}

	if(workdir == nil)
		workdir = root + "/work";
	sys->pctl(Sys->FORKNS, nil);

	devnull = sys->open("#c/null", Sys->ORDWR);
	timefd = sys->open("/dev/time", Sys->OREAD);
	if(timefd == nil){
		logerror(sys->sprint("cannot open /dev/time: %r"));
		raise "fail:no time";
	}
	starttime = now();

	sysname := readfile("/dev/sysname", 1);
	if (sysname != nil && sysname[len sysname - 1] == '\n')
		sysname = sysname[: len sysname - 1];
	if(sysname == nil)
		logerror(sys->sprint("no sysname set"));
	if(procname != nil)
		sysname += "["+procname+"]";

	attrcheck = chan[1] of int;
	attrcheck <-= 1;
	down = chan of (ref Task, int);
	worktoken = chan[ncpu] of int;
	tasklock = chan[1] of int;
	spacelock = chan[1] of int;
	used = ref File;
	used.next = used.prev = used;
	stopc = array[ncpu] of {* => chan of string};

	spawn attrpromptproc();
	spawn mountproc(addr, sysname);

	files = Strhash[ref File].new(17, nil);
	(d, nil) := readdir->init(workdir, Readdir->ATIME|Readdir->DESCENDING|Readdir->COMPACT);
	# read details of all current files to restore files list.
	# XXX how to restore LRU order? (atime ain't good enough)
	for(i := 0; i < len d; i++){
		name := d[i].name;
		if(name == nil || (d[i].mode & Sys->DMDIR) == 0 || name[0] != 'h')
			continue;
		(f, err) := File.restore(workdir+"/"+name);
		if(f == nil){
			logerror(sys->sprint("cannot restore %s/%s: %s", workdir, name, err));
			remove(workdir+"/"+name);	# XXX if this fails, then reduce cachesize by space taken.
			continue;
		}
		files.add(hashtext(f.hash), f);
		f.use();
		nfiles++;
		actused += f.size;
	}
	log(sys->sprint("found %d cached files taking %bd bytes", nfiles, actused));

	# look through workdir and see if we can find any tasks that
	# are eligible for resubmission.
	using := array[ncpu] of {* => 0};
	excl: ref Task;
	tasks: list of ref Task;
	for(i = 0; i < len d; i++){
		name := d[i].name;
		if(name == nil || (d[i].mode & Sys->DMDIR) == 0 || name[0] < '0' || name[0] > '9')
			continue;
		workid := int name;
		if((t := Task.restore(workid)) != nil){
			tasks = t :: tasks;
			if(workid < ncpu)
				using[workid] = 1;
			if(t.exclusive)
				excl = t;
		}else if(workid >= ncpu){
			remove(workdir+"/"+name);
			remove(workdir+"/"+name+".info");
			remove(workdir+"/"+name+".info.finished");
		}
	}
	# we should never have an exclusive task along
	# with any other task, but if we do, then discard
	# any other tasks.
	if(excl != nil){
		log("restoring exclusive task");
		tasklock <-= 1;
		down <-= (excl, 0);
		for(i = 1; i < ncpu; i++)
			down <-= (nil, 0);
	}else{
		for(; tasks != nil; tasks = tl tasks){
			log("restoring task "+string (hd tasks).workid);
			down <-= (hd tasks, 0);
		}
		for(i = 0; i < ncpu; i++){
			if(using[i] == 0){
				worktoken <-= i;
				down <-= (nil, 0);
			}
		}
	}
	using = nil;
	excl = nil;
	<-chan of int;
}

mountproc(addr, sysname: string)
{
	sys->chdir(SCHEDDIR);
	version := 0;
	for(;;){
		(task, v) := <-down;
		if(v == version){
			log("re-mounting server");
			sys->pctl(Sys->FORKNS, nil);
			stopfd := mountsrv(addr, sysname);
			spawn stoptask(stopfd);
			spawn pollserver();
			++version;
		}
		spawn processor(sync := chan of int, version, task);
		<-sync;
	}
}

# poll server occasionally, so that if other threads are
# blocked on a read and the server is killed unexpectedly,
# we will trigger a TCP response.
pollserver()
{
	for(;;){
		sys->sleep(POLL);
		if(sys->stat(SCHEDDIR).t0 == -1)
			exit;
	}
}

attrpromptproc()
{
	for(;;){
		sys->sleep(ATTRCHECK);
		alt{
		attrcheck <-= 1 =>
			;
		* =>
			;
		}
	}
}

processor(sync: chan of int, mversion: int, task: ref Task)
{
	log(sys->sprint("new processor (version %d)", mversion));
	sys->pctl(Sys->FORKNS, nil);		# guard against chdir side-effects.
	sync <-= 0;

	if(task != nil){
		# if we're given an already existing task, it
		# can only be an already completed, but not yet
		# submitted task, with appropriate lock and workid's already acquired
		# if it's exclusive.
		spawn reconnect(task, reply := chan of (string, int));
		(err, tryagain) := <-reply;
		if(err != nil){
			logerror(sys->sprint("reconnect failed: %s", err));
			if (tryagain && !mounted()){
				# assume hangup in reconnect()
				down <-= (task, mversion);
				exit;
			}
		}
		task.finish();
		# harvest extra workers if number of processors has dropped.
		if(task.workid >= ncpu){
			remove(task.workdir());
			exit;
		}
	}
	pid := sys->pctl(0, nil);
	for(;;){
		spawn runtask(reply := chan of (string, ref Task));
		(err, t) := <-reply;
		if(err != nil){
			logerror(sys->sprint("%d run new task failed: %s", pid, err));
			if(!mounted()){
				log(sys->sprint("processor down (version %d)", mversion));
				down <-= (t, mversion);
				exit;
			}
			# if it's still mounted, then no point reconnectting - the scheduler
			# has told us where to go.
			# XXX except... what if the person running the scheduler
			# had an auth key mixup and suddenly denied access to
			# legitimate clients.
			if(t != nil)
				t.finish();
		}
	}
}

runtask(reply: chan of (string, ref Task))
{
	sys->pctl(Sys->FORKENV|Sys->FORKNS, nil);
	reply <-= runtask1();
}

# get a new task to run; acquire its resources; run it
runtask1(): (string, ref Task)
{
	Cleanup: exception(string);
	tasklock <-= 1;
	alt{
	<-attrcheck=>
		checkattrs();
	* =>
		break;
	}
	# XXX while we're blocked opening this, we can't check attributes;
	# we could do the open in another proc to accomplish this, but
	# it's probably overkill.
	log("opening task");
	fd := sys->open("task", Sys->ORDWR);
	if(fd == nil){
		<-tasklock;
		return (sys->sprint("cannot open task: %r"), nil);
	}
	(t, err) := Task.readnew(fd);
	if(t == nil){
		<-tasklock;
		return (err, nil);
	}
	ctxt: ref Sh->Context;
	(ctxt, err) = loadjobtype(hd t.argv);
	if(ctxt == nil){
		<-tasklock;
		return (sys->sprint("cannot load job type %q: %s", hd t.argv, err), nil);
	}
	t.exclusive = isexclusive(ctxt, t.argv);
	if(t.exclusive)
		log(sys->sprint("task %q is exclusive", t.srvid));
	(ok, fetch) := t.getspace();
	if(ok == -1){
		<-tasklock;
		return ("not enough space for task "+t.srvid, nil);
	}

	t.workid = getworkid(t.exclusive);
	ctxt.set("work", ref Sh->Listnode(nil, t.workdir()) :: nil);

	errs := 0;
	if(sys->fprint(fd, "%s", t.clientid()) == -1){
		log(sys->sprint("cannot write client id: %r"));
		errs++;
	}

	# get the files we're responsible for fetching.
	for(; fetch != nil; fetch = tl fetch){
		f := hd fetch;
		if((err = f.fetch(fd)) != nil){
			log(sys->sprint("error getting %s (path %s): %s", f.name, f.path, err));
			remove(f.path);		# XXX if failed, reduce cachesize by unremoved disk usage
			errs++;
		}
		<-f.fetchlock;
	}

	stdin := fd;
	# wait for all the others to be fetched.
	for(fl := t.files; fl != nil; fl = tl fl){
		f := hd fl;
		f.fetchlock <-= 1;
		# perhaps another transfer that we've been waiting on
		# has died for some unrelated reason (e.g. couldn't write clientid), so we'll try
		# fetching the file ourselves, just in case.
		if(!f.fetched){
			if((err = f.fetch(fd)) != nil){
				log(sys->sprint("couldn't refetch %s (path %s): %s", f.name, f.path, err));
				remove(f.path);
				errs++;
			}
		}
		<-f.fetchlock;
		if(!f.fetched)
			errs++;
		else if(f.kind == "stdin"){
			stdin = sys->open(f.path+"/data", Sys->OREAD);
			if(stdin == nil){
				log(sys->sprint("cannot open %q as stdin: %r", f.path+"/data"));
				errs++;
			}
		}
	}
	if(t.files != nil)
		if(sys->fprint(fd, "end") == -1){
			log(sys->sprint("error writing 'end': %r"));
			errs++;
		}
	{
		if(errs)
			raise Cleanup("cannot get input files");

		if((err = prepareworkdir(t)) != nil)
			raise Cleanup(err);

		expirepid := -1;
		if(t.deadline != -1){
			spawn expireproc(pidc := chan of int, t.deadline - now(), stopc[t.workid], t.clientid());
			expirepid = <-pidc;
		}
		for(fl = t.files; fl != nil; fl = tl fl){
			f := hd fl;
			if(f.kind != "stdin")
				ctxt.set(f.name, ref Sh->Listnode(nil, f.path+"/"+f.name) :: nil);
		}
		for(vl := t.values; vl != nil; vl = tl vl)
			ctxt.set((hd vl).t0, sh->stringlist2list((hd vl).t1));

		# actually run the task
		err = runtask2(t, ctxt, stdin, fd);

		kill(expirepid, "kill");

		# if there's an error and the task has been done,
		# then send it back for possible resubmission,
		# keeping held its locks and work id.
		if(err != nil && t.done){
			fd = nil;
			return (err, t);
		}
		raise Cleanup(nil);
	}exception e{
	Cleanup =>
		spacelock <-= 1;
		for(fl = t.files; fl != nil; fl = tl fl)
			if(--(hd fl).refcount == 0)
				currused -= (hd fl).size;
		<-spacelock;
		t.finish();
		return (e, nil);
	}
}

runtask2(t: ref Task, ctxt: ref Sh->Context, fd0, fd1: ref Sys->FD): string
{
	if(fd0 == nil)
		fd0 = fd1;
	fd2 := sys->create(t.workdir()+".err", Sys->ORDWR, 8r666);
	err := runsubtask(ctxt, "runtask" :: tl t.argv, stopc[t.workid], t.clientid(), fd0, fd1, fd2);
	if(err != nil)
		return err;
	t.save();
	if(t.outkind == "bundle"){
		d := ".";
		if((v := ctxt.get("output")) != nil)
			d = (hd v).word;
		# XXX bundle errors go unreported.
		err = bundle->bundle(d, fd1);
	}else
		err = runsubtask(ctxt, "submit" :: tl t.argv, stopc[t.workid], t.clientid(), devnull, fd1, fd2);
	sys->write(fd1, array[0] of byte, 0);
	if(fd2 != nil)
		senderrors(fd2, fd1);
	if(err != nil)
		return err;

	# special task type 'update' causes version info to be updated.
	# args look like:
	# upate pkg md5 version action...
	if(hd t.argv == "update" && len t.argv >= 5){
		argv := tl t.argv;
		updated(hd argv, hd tl argv, hd tl tl argv);
	}
	return nil;
}

reconnect(task: ref Task, reply: chan of (string, int))
{
	sys->pctl(Sys->FORKENV|Sys->FORKNS, nil);
	reply <-= reconnect1(task);
}

# return (error, tryagain)
reconnect1(t: ref Task): (string, int)
{
	(ctxt, err) := loadjobtype(hd t.argv);
	if(ctxt == nil)
		return (sys->sprint("cannot load jobtype %q: %s", hd t.argv, err), 0);

	fd := sys->open("reconnect", Sys->ORDWR);
	if(fd == nil){
		# could check for "Hangup" error message here.
		return (sys->sprint("cannot open reconnect: %r"), 0);
	}

	work := t.workdir();
	ctxt.set("work", ref Sh->Listnode(nil, work) :: nil);
	sys->chdir(work);
	log(sys->sprint("trying to reconnect to task %#q", t.srvid));

	if(sys->fprint(fd, "%s", t.srvid) < 0)
		return (sys->sprint("%r"), 0);
	if(sys->fprint(fd, "%s", t.clientid()) < 0)
		return (sys->sprint("cannot write clientid: %r"), 1);
	log("reconnect opened ok");
	errfd := sys->open(t.workdir()+".err", Sys->ORDWR);
	if(errfd == nil)
		log(sys->sprint("cannot open old errfile %s: %r", t.workdir()+".err"));
	else
		sys->seek(errfd, big 0, Sys->SEEKEND);

	err = runsubtask(ctxt, "submit"::tl t.argv, stopc[t.workid], t.clientid(), devnull, fd, errfd);
	if(err == nil)
		sys->write(fd, array[0] of byte, 0);
	if(errfd != nil)
		senderrors(errfd, fd);
	return (err, 1);
}

senderrors(errfd, fd: ref Sys->FD)
{
	sys->seek(errfd, big 0, Sys->SEEKSTART);
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(errfd, buf, len buf)) > 0)
		if(sys->write(fd, buf, n) != n)
			break;
}

runsubtask(ctxt: ref Sh->Context, cmd: list of string,
		stopc: chan of string, clientid: string, fd0, fd1, fd2: ref Sys->FD): string
{
	pidc := chan of int;
	res := chan of string;
	spawn scriptproc(ctxt, pidc, res, cmd, fd0, fd1, fd2);
	scriptpid := <-pidc;
	for(;;) alt{
	status := <-res =>
		if (status != nil){
			log(sys->sprint("error executing %q: %s", hd cmd, status));
			return status;
		}
		return nil;
	stopid := <-stopc =>
		if (stopid != clientid){
			log(sys->sprint("asked to kill alien task %q", stopid));
			continue;
		}
		kill(scriptpid, "killgrp");
		if(ctxt.get("fn-killtask") != nil)
			runscript(ctxt, "killtask"::nil, devnull, devnull, nil);
		return "stopped";
	}
}

isexclusive(ctxt: ref Sh->Context, jobargs: list of string): int
{
	if(ctxt.get("fn-exclusive") == nil)
		return 0;
	return run(ctxt, "exclusive" :: tl jobargs) == nil;
}

# called with tasklock held.
# if exclusive is true, tasklock remains held and all work ids are gathered in.
getworkid(exclusive: int): int
{
	if(exclusive){
		for(i := 0; i < ncpu; i++)
			<-worktoken;
		return 0;
	}else{
		<-tasklock;
		return <-worktoken;
	}
}

putworkid(id: int, exclusive: int)
{
	if(exclusive){
		for(i := 0; i < ncpu; i++)
			worktoken <-= i;
		<-tasklock;
	}else if(id < ncpu)
		worktoken <-= id;
}

expireproc(pidc: chan of int, deadline: int, stopc: chan of string, clientid: string)
{
	pidc <-= sys->pctl(0, nil);
	d := deadline;
	while(d > 0){
		t: int;
		if(d >= 16r7fffffff / 1000)
			t = 16r7fffffff / 1000;
		else
			t = d;
		sys->sleep(t * 1000);
		d -= t;
	}
	log("deadline ("+string deadline+" seconds) expired");
	stopc <-= clientid;
}

# read a new task from the scheduler.
Task.readnew(fd: ref Sys->FD): (ref Task, string)
{
	t := ref Blanktask;
	t.deadline = -1;

	idl := str->unquoted(reads(fd));
	if(idl == nil)
		return (nil, sys->sprint("failed to read task id: %r"));
	(t.srvid, idl) = (hd idl, tl idl);
	d := int hd idl;
	if(d == 0)
		return (nil, "zero deadline");
	t.deadline = now() + d;
	log(sys->sprint("got task %s, deadline %d", t.srvid, t.deadline));

	buf := array[Sys->ATOMICIO] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return (nil, sys->sprint("task read error: %r"));
	if(n == 0)
		return (nil, "premature eof on task");
	# old style
	if(buf[0] != byte '('){
		t.argv = str->unquoted(string buf[0:n]);
		if(t.argv == nil)
			return (nil, "no job type found");
		return (t, nil);
	}
	# new style
	(se, nil, err) := Sexp.unpack(buf);
	if(se == nil)
		return (nil, err);
	log("got task "+se.text());
	if(!se.islist() || se.op() != "task")
		return (nil, "bad s-expression "+se.text());
	for(ta := se.args(); ta != nil; ta = tl ta){
		case (hd ta).op() {
		"args" =>
			# (args taskname [arg...])
			if((t.argv = stringlist((hd ta).args())) == nil)
				return (nil, "no task type found");
		"input" =>
			# (input [(file...)])
			for(els := (hd ta).args(); els != nil; els = tl els){
				case (hd els).op(){
				"file" =>
					(f, e) := File.parse(hd els);
					if(f == nil)
						return (nil, e);
					t.files = f :: t.files;
				"value" =>
					# (value tag [val...])
					a := (hd els).args();
					if(a == nil || (hd a).islist())
						return (nil, "value lacks tag");
					t.values = ((hd a).astext(), stringlist(tl a)) :: t.values;
				}
			}
		"output" =>
			# (output kind)
			els := (hd ta).args();
			if(els == nil || tl els != nil)
				return (nil, "bad output kind");
			t.outkind = (hd els).astext();
			case t.outkind {
			"bundle" or
			"data" =>
				;
			* =>
				return (nil, sys->sprint("bad output kind %q", t.outkind));
			}
		}
	}
	return (t, nil);
}

stringlist(els: list of ref Sexp): list of string
{
	l: list of string;
	for(; els != nil; els = tl els)
		l = (hd els).astext() :: l;
	return rev(l);
}

# wait for enough space to become available to run the task;
# return status and the list of files that need to be fetched,
# all of which are locked pending their fetch (which we want
# to do outside tasklock so that we can fetch several files at a time).
# called with tasklock held.
Task.getspace(t: self ref Task): (int, list of ref File)
{
	reqspace := big 0;
	for(fl := t.files; fl != nil; fl = tl fl)
		reqspace += (hd fl).size;
	if(reqspace > cachesize)
		return (-1, nil);
	# replace any required files by those that are already available.
	fetch, tfiles: list of ref File;
	newused := big 0;
	spacelock <-= 1;
	for(fl = t.files; fl != nil; fl = tl fl){
		f := hd fl;
		h := hashtext(f.hash);
		if((oldf := files.find(h)) != nil &&
				oldf.name == f.name &&
				oldf.kind == f.kind){
			reqspace -= f.size;
			f = oldf;
		}else{
			f.fetchlock <-= 1;
			files.add(h, f);
			fetch = f :: fetch;
		}
		f.use();
		if(f.refcount++ == 0)
			newused += f.size;
		tfiles = f :: tfiles;
	}
	t.files = tfiles;

	# wait for other tasks to complete until there's
	# enough disk space free. (note that new tasks can't start
	# up as we hold tasklock).
	toks: list of int;
	for(;;){
		if(cachesize - currused >= reqspace)
			break;
		<-spacelock;
		toks = <-worktoken :: toks;
		spacelock <-= 1;
	}

	# now free up enough unused files to actually make the space.
	# also prune unused files above our file-count limit.
	next: ref File;
	for(f := used.next; f != used; f = next){
		if(cachesize - actused >= reqspace && nfiles < maxfiles)
			break;
		next = f.next;
		if(f.refcount == 0)
			if(f.remove() == -1){
				# XXX what should we do if we can't remove a file that's not being used? - reduce cachesize by amount still taken; check we've still got enough space.
			}
	}
	if(cachesize - actused < reqspace){
		log(sys->sprint("shouldn't happen: space still not available (req %bd act %bd used %bd)", reqspace, actused, reqspace));
		for(; fetch != nil; fetch = tl fetch)
			<-(hd fetch).fetchlock;
		<-spacelock;
		return (-1, nil);
	}
	currused += newused;
	<-spacelock;

	# give back the tokens we stole, now we've got the space.
	for(; toks != nil; toks = tl toks)
		worktoken <-= hd toks;
	return (0, fetch);
}

Task.workdir(t: self ref Task): string
{
	return workdir+"/"+string t.workid;
}

Task.clientid(t: self ref Task): string
{
	return sys->sprint("%d.%s", t.workid, t.srvid);
}

Task.save(t: self ref Task)
{
	fd := sys->create(t.workdir()+".info", Sys->OWRITE, 8r666);
	if (fd == nil){
		logerror(sys->sprint("cannot create task info file %#q: %r", t.workdir()+".info"));
		return;
	}
	sys->fprint(fd, "%d %q %s", t.exclusive, t.srvid, str->quoted(t.argv));
	t.done = 1;
}

Task.restore(workid: int): ref Task
{
	t := ref Blanktask;
	t.workid = workid;
	t.done = 1;

	info := readfile(t.workdir()+".info", 0);
	if(info == nil)
		return nil;

	toks := str->unquoted(info);
	if (len toks < 3){
		logerror("bad data in old task info for workid "+string workid);
		return nil;
	}

	t.exclusive = int hd toks;
	t.srvid = hd tl toks;
	t.argv = tl tl toks;
	return t;
}

Task.finish(t: self ref Task)
{
	if(t.workid != -1)
		putworkid(t.workid, t.exclusive);
	if(t.done){
		d := Sys->nulldir;
		d.name = string t.workid+".info.finished";
		sys->wstat(t.workdir()+".info", d);
	}
}

File.parse(se: ref Sexp): (ref File, string)
{
	# format:
	# (file _name_ _hash_ _size_ _kind_)
	if(!se.islist() || se.op() != "file")
		return (nil, sys->sprint("expected (file), got %s", se.text()));
	els := se.args();
	if(len els < 4)
		return (nil, sys->sprint("too few args to (file), got %s", se.text()));
	f := ref blankfile;
	(f.name, els) = ((hd els).astext(), tl els);
	(f.hash, els) = ((hd els).asdata(), tl els);
	h := "h" + hashtext(f.hash);
	if(len h > Maxname)
		h = h[0:Maxname];
	f.path = workdir+"/"+h;
	(f.size, els) = (big (hd els).astext(), tl els);
	(f.kind, els) = ((hd els).astext(), tl els);
	if(f.kind == "stdin")
		f.name = "data";
	f.fetchlock = chan[1] of int;
	f.details = se;
	return (f, nil);
}

File.restore(d: string): (ref File, string)
{
	iob := bufio->open(d+"/details", Sys->OREAD);
	if(iob == nil)
		return (nil, sys->sprint("cannot open details: %r"));
	(se, err) := Sexp.read(iob);
	if(se == nil)
		return (nil, sys->sprint("cannot parse details: %r"));
	f: ref File;
	(f, err) = File.parse(se);
	if(f == nil)
		return (nil, "cannot parse details: "+err);
	if(f.path != d)
		return (nil, "non-matching directory name");
	# XXX check that data file still matches hash?
	f.fetched = 1;
	return (f, nil);
}

# move to the top of the LRU cache.
# called with spacelock held.
File.use(f: self ref File)
{
	if(f.next != nil){
		f.next.prev = f.prev;
		f.prev.next = f.next;
	}
	f.next = used;
	f.prev = used.prev;
	f.prev.next = f;
	used.prev = f;
}

# called with spacelock held.
File.remove(f: self ref File): int
{
	f.next.prev = f.prev;
	f.prev.next = f.next;
	f.next = nil;
	f.prev = nil;
	if(f.fetched){
		remove(f.path);
		# XXX if remove error: cachesize -= du(f.path);
		actused -= f.size;
		nfiles--;
	}
	files.del(hashtext(f.hash));
	if(sys->stat(f.path).t0 != -1)
		return -1;
	return 0;
}

# called with f.fetchlock held.
File.fetch(f: self ref File, fd: ref Sys->FD): string
{
	p := f.path;
	if(sys->write(fd, f.hash, len f.hash) == -1)
		return sys->sprint("file request refused: %r");

	if(mkdir(p) == -1)
		return sys->sprint("cannot mkdir %q: %r", p);

	dfd := sys->create(p+"/_details", Sys->OWRITE, 8r666);
	if(dfd == nil)
		return sys->sprint("cannot create %q: %r", p+"/_data");

	ofd: ref Sys->FD;
	bsync: chan of string;
	if(f.kind == "bundle"){
		sys->pipe(pfd := array[2] of ref Sys->FD);
		ofd = pfd[1];
		spawn unbundleproc(pfd[0], p+"/_data", bsync = chan[1] of string);
	}else{
		ofd = sys->create(p+"/_data", Sys->OWRITE, 8r666);
		if(ofd == nil)
			return sys->sprint("cannot create %q: %r", p+"/_data");
	}

	# XXX should check the size as we're downloading it, to
	# make sure it doesn't exceed advertised size.
	state: ref Keyring->DigestState;
	buf := array[Sys->ATOMICIO] of byte;
	size := big 0;
	while((n := sys->read(fd, buf, len buf)) > 0){
		if(sys->write(ofd, buf, n) != n)
			return sys->sprint("write error: %r");
		size += big n;
		state = keyring->md5(buf, n, nil, state);
	}exception{
	"write on closed pipe" =>
		return "error on unbundle";
	}
	keyring->md5(buf, 0, checkhash := array[Keyring->MD5dlen] of byte, state);
	if(!beq(checkhash, f.hash))
		return sys->sprint("hash does not match (expected %s, got %s, %bd bytes)", hashtext(f.hash), hashtext(checkhash), size);
	checkhash = nil;
	d := Sys->nulldir;
	case f.kind {
	"data" or
	"stdin" =>
		d.name = f.name;
		if(sys->fwstat(ofd, d) == -1)
			return sys->sprint("cannot rename _data to %q: %r", d.name);
	"bundle" =>
		if((err := <-bsync) != nil)
			return "unbundle failed: "+err;
		d.name = f.name;
		if(sys->wstat(p+"/_data", d) == -1)
			return sys->sprint("cannot rename _data directory to %q: %r", d.name);
	* =>
		return sys->sprint("unknown file kind %#q", f.kind);
	}
	ofd = nil;
	buf = nil;

	# record details of the data, so we can pick it up again after restart. (advanced form for editing convenience)
	if(sys->fprint(dfd, "%s\n", f.details.text()) == -1)
		return sys->sprint("cannot write details: %r");
	d.name = "details";
	if(sys->fwstat(dfd, d) == -1)
		return sys->sprint("cannot rename _details to details: %r");
	f.fetched = 1;
	spacelock <-= 1;
	actused += f.size;
	nfiles++;
	<-spacelock;
	return nil;
}

unbundleproc(fd: ref Sys->FD, dir: string, bsync: chan of string)
{
	bsync <-= bundle->unbundle(fd, dir);
}

beq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hashtext(hash: array of byte): string
{
	s := "";
	for(i := 0; i < len hash; i++)
		s += sys->sprint("%.2x", int hash[i]);
	return s;
}

updated(pkg, md5, vers: string)
{
	v := md5+"."+vers;
	versionattrs = versionattrs.add("version_"+pkg, v);
	writeattrs(root+"/version", versionattrs);
	checkattrs();
}
	
mountsrv(addr, sysname: string): ref Sys->FD
{
	backoff := 0;
	for(;;){
		log("attempting to mount server");
		if((err := domount(addr)) == nil){
			# open here so that we back off even if it's just permission denied.
			if(sysname != nil)
				sys->fprint(sys->open(SCHEDDIR+"/nodename", Sys->OWRITE), "%s", sysname);
			stopfd := sys->open(SCHEDDIR+"/stoptask", Sys->OREAD);
			if(stopfd != nil){
				a := currattrs;
				if(len a.a > 0)
					writeattrs(SCHEDDIR+"/attrs", a);
				log("mounted server ok");
				return stopfd;
			}
			log("mounted, but cannot open stoptask: %r");
		}
		log("failed to mount server: "+err);
		if(backoff == 0)
			backoff = 1000 + rand->rand(500) - 250;
		else if(backoff < MAXBACKOFF)
			backoff = backoff * 3 / 2;
		sys->sleep(backoff);
	}
}

stoptask(stopfd: ref Sys->FD)
{
	while((id := reads(stopfd)) != nil){
		log(sys->sprint("asked to kill %#q", id));
		if(id[0] < '0' || id[0] > '9'){
			logerror(sys->sprint("stoptask invalid clientid %#q", id));
			continue;
		}
		stopc[int id] <-= id;
	}
	log("eof on stoptask");
}

domount(addr: string): string
{
	sys->unmount(nil, SCHEDDIR);
	flag := Mount->MREPL;
	if(noauth)
		flag |= Mount->MNOAUTH;
	keyspec := "";
	if(keyfile != nil)
		keyspec = "key="+keyfile+"";
	(ok, s) := mount->mount(addr, SCHEDDIR, flag, nil, nil, keyspec);
	if(ok == -1)
		return s;
	if(!noauth && schedid != nil && schedid != s)
		return sys->sprint("%q is running scheduler; expected %q", s, schedid);
	return nil;
}

# is scheduler still mounted? (quick and dirty test)
mounted(): int
{
	return sys->stat(SCHEDDIR+"/task").t0 != -1;
}

loadjobtype(jobtype: string): (ref Context, string)
{
	for(i := 0; i < len jobtype; i++)
		if(jobtype[i] == '/')
			return (nil, "invalid job type name");

	ctxt := Context.new(nil);
	err := run(ctxt, "run" :: root + "/" + jobtype + ".job" :: nil);
	if(err != nil)
		return (nil, err);

	if(ctxt.get("fn-runtask") == nil)
		return (nil, "function runtask has not been defined");
	if(ctxt.get("fn-submit") == nil)
		return (nil, "function submit has not been defined");
	ctxt.set("root", ref Sh->Listnode(nil, root) :: nil);
	for(i = 0; i < len nodeattrs.a; i++)
		ctxt.set(nodeattrs.a[i].t0, ref Sh->Listnode(nil, nodeattrs.a[i].t1) :: nil);
	return (ctxt, nil);
}

prepareworkdir(t: ref Task): string
{
	work := t.workdir();
	if(remove(work) == -1)
		return sys->sprint("cannot remove %#q", work);
	remove(work+".info");
	remove(work+".info.finished");
	if(mkdir(work) == -1)
		return sys->sprint("cannot mkdir %#q: %r", work);
	if(sys->chdir(work) == -1)
		return sys->sprint("cannot cd to %s: %r", work);
	return nil;
}

# re-write attributes if they've changed.
# called non-reentrantly.
checkattrs()
{
	versionattrs = readattrs(root + "/version");
	a := getattrs();
	if(len a.a == len currattrs.a){
		for(i := 0; i < len a.a; i++)
			if(a.a[i].t0 != currattrs.a[i].t0 || a.a[i].t1 != currattrs.a[i].t1)
				break;
		if(i == len a.a)
			return;
	}
	log("attributes changed");
	if(writeattrs(SCHEDDIR+"/attrs", a) != -1)
		currattrs = a;
}

readattrs(f: string): Attrs[string]
{
	a: Attrs[string];
	iob := bufio->open(f, Sys->OREAD);
	if(iob == nil){
		logerror(sys->sprint("cannot read %q: %r", f));
		return a;
	}
	while((s := iob.gets('\n')) != nil){
		v := str->unquoted(s);
		if(len v == 2)
			a = a.add(hd v, hd tl v);
	}
	return a;
}

writeattrs(f: string, a: Attrs[string]): int
{
	fd := sys->open(f, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil){
		logerror(sys->sprint("cannot open %q: %r", f));
		return -1;
	}
	buf := array[Sys->ATOMICIO] of byte;
	n := 0;
	for(i := 0; i < len a.a; i++){
		x := sys->aprint("%q %q\n", a.a[i].t0, a.a[i].t1);
		if(len x > len buf - n){
			if(n == 0){
				logerror(sys->sprint("attribute too long (%q, %d bytes)", a.a[i].t0, len x));
				continue;
			}
			if(sys->write(fd, buf, n) != n){
				logerror(sys->sprint("attribute write failed: %r"));
				return -1;
			}
			n = 0;
		}
		buf[n:] = x;
		n += len x;
	}
	if(n > 0 && sys->write(fd, buf, n) != n){
		logerror(sys->sprint("attribute write failed: %r"));
		return -1;
	}
	return 0;
}

getattrs(): Attrs[string]
{
	a := nodeattrs.merge(versionattrs);
	id := 0;
	a = a.add("cachesize", string cachesize);
	# get the set of job types that we know about
	(dirs, n) := readdir->init(root, Readdir->NAME|Readdir->COMPACT);
	for (i := 0; i < n; i++){
		name := dirs[i].name;
		if(hassuffix(name, ".job") && (dirs[i].qid.qtype & Sys->QTDIR) == 0){
			v := name[0:len name - 4];
			a = a.add("jobtype"+string id++, v);
		}
	}
	return a;
}

hassuffix(s, suff: string): int
{
	return len s >= len suff && s[len s - len suff:] == suff;
}

runscript(ctxt: ref Context, argv: list of string, stdin, stdout, stderr: ref Sys->FD): string
{
	pidc := chan of int;
	res := chan of string;
	spawn scriptproc(ctxt, pidc, res, argv, stdin, stdout, stderr);
	<-pidc;
	return <-res;
}

scriptproc(ctxt: ref Sh->Context, sync: chan of int, rc: chan of string, argv: list of string, stdin, stdout, stderr: ref Sys->FD)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->FORKFD, nil);
	sys->dup(stdin.fd, 0);
	sys->dup(stdout.fd, 1);
	if(stderr != nil)
		sys->dup(stderr.fd, 2);
	stdin = nil;
	stdout = nil;
	stderr = nil;
	sync <-= sys->pctl(Sys->NEWFD, 0::1::2::nil);
	nctxt := ctxt.copy(0);
	ctxt = nil;
	status := run(nctxt, argv);
	rc <-= status;
}

badmodule(path: string)
{
	logerror(sys->sprint("cannot load %s: %r", path));
	raise "fail:load";
}

logerror(msg: string)
{
	sys->fprint(stderr(), "worker: %s\n", msg);
}

log(msg: string)
{
	if (verbose)
		sys->fprint(stderr(), "worker: %s\n", msg);
}

stderr(): ref sys->FD
{
	return sys->fildes(2);
}

kill(pid: int, note: string)
{
	sys->fprint(sys->open("#p/"+string pid+"/ctl", Sys->OWRITE), "%s", note);
}

readfile(f: string, warn: int): string
{
	buf := array[8192] of byte;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		if(warn)
			logerror(sys->sprint("cannot open %q: %r", f));
		return nil;
	}
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

reads(fd: ref Sys->FD): string
{
	buf := array[Sys->ATOMICIO] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		logerror(sys->sprint("error on read: %r"));
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

writefile(f: string, s: string): int
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	d := array of byte s;
	if(len d > Sys->ATOMICIO)
		logerror(sys->sprint("write too big on %s", f));
	if(sys->write(fd, d, len d) == -1){
		logerror(sys->sprint("write to %q failed: %r", f));
		return -1;
	}
	return 0;
}

units(s: string): big
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			break;
	b := big s;
	if(i == len s)
		return b;
	case s[i:] {
	"k" or "K" or "KB" =>
		return b * big 1024;
	"m" or "M" or "MB" =>
		return b * big 1024 * big 1024;
	"g" or "G" or "GB" =>
		return b * big 1024 * big 1024 * big 1024;
	* =>
		return big -1;
	}
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
			logerror(sys->sprint("cannot remove %q: %r", path));
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
		logerror(sys->sprint("cannot remove %q: %r", path));
		r = -1;
	}
	return r;
}

mkdir(path: string): int
{
	if((fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777)) == nil)
		return -1;
	# XXX this wstat is only to get around broken windows file systems, and needs removing!
	d := Sys->nulldir;
	d.mode = Sys->DMDIR|8r777;
	sys->fwstat(fd, d);
	return 0;
}

run(shctxt: ref Context, argv: list of string): string
{
	{
		return shctxt.run(sh->stringlist2list(argv), 0);
	} exception e {
	"fail:*" =>
		return e[5:];
	}
}

relpath(p: string, d: string): string
{
	if(p != nil && p[0] == '/' || len p > 1 && p[0] == '.' && p[1] == '/')
		return p;
	return d+"/"+p;
}

now(): int
{
	buf := array[24] of byte;
	n := sys->pread(timefd, buf, len buf, big 0);
	if(n <= 0)
		return 0;
	return int (big string buf[0:n] / big 1000000);
}

rev[T](x: list of T): list of T
{
	l: list of T;
	for(; x != nil; x = tl x)
		l = hd x :: l;
	return l;
}
