implement Taskgenerator, Taskgenmod;
include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "readdir.m";
	readdir: Readdir;
include "sh.m";
	sh: Sh;
	Context: import sh;
include "attributes.m";
include "arg.m";
include "taskgenerator.m";
include "tgself.m";

rootdir: string;
workdir: string;

jobtype: string;
ntasks: int;

nexttask: chan of string;
waitfortask: chan of (string, chan of int);
getuniqid: chan of string;
getstate: chan of chan of string;

verbose := 0;
maxretries := 10;
pendtasks := 10;
ctxt: ref Context;
ctxtlock: chan of int;

init(root, work, state: string, nil: chan of int, argv: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgself := load TGself TGself->PATH;
	if(tgself == nil)
		return (nil, sys->sprint("cannot load %s: %r", TGself->PATH));
	gen := load Taskgenmod "$self";
	if(gen == nil)
		return (nil, sys->sprint("cannot self as Taskgenmod: %r"));
	rootdir = root;
	workdir = work;
	return tgself->init(state, argv, gen);
}

tginit(state: string, argv: list of string): string
{
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load %s: %r", String->PATH);
	sh = load Sh Sh->PATH;
	if (sh == nil)
		return sys->sprint("cannot load %s: %r", Sh->PATH);
	ctxt = Context.new(nil);
	ctxtlock = chan[1] of int;
	arg := load Arg Arg->PATH;
	arg->init(argv);

	USAGE: con "script [-v] [-p npending] [-r maxretries] jobtype jobargs...";
	while((opt := arg->opt()) != 0){
		case opt {
		'r' =>
			maxretries = int arg->arg();
			if (maxretries <= 0)
				return USAGE;
		'p' =>
			pendtasks = int arg->arg();
			if (pendtasks <= 0)
				return USAGE;
		'v' =>
			verbose = 1;
		* =>
			return USAGE;
		}
	}
	argv = arg->argv();
	if(argv == nil)
		return USAGE;
	arg = nil;

	jobtype = hd argv;
	argv = tl argv;

	script := rootdir+"/"+jobtype + ".job" ;
	err := run(ctxt, "run" :: script :: nil);
	if(err != nil)
		return script + " failed: " + err;

	err = checkjobfns();
	if (err != nil)
		return err;

	nexttask = chan of string;
	waitfortask = chan of (string, chan of int);
	getuniqid = chan of string;
	getstate = chan of chan of string;

	if (state == nil) {
		# start of new job
		err = runscript("mkjob"::argv, devnull(), logfd());
		if (err != nil)
			return err;
		err = getntasks();
		if (err != nil)
			return err;
		spawn taskmon(0, 0, 0);
		return nil;
	}

	# restart of job
	if (len state < 3*12)
		return "bad state";

	nprep := int state[0:12];
	nsched := int state[12:24];
	nseq := int state[24:36];

	# sanity check
	if (nprep < 0 || nsched < 0 || nseq < 0 || nsched > nprep){
		log(sys->sprint("restart in inconsistent state %q, nprep %d, nsched %d, nseq %d",
			state, nprep, nsched, nseq));
		return "inconsistent state";
	}
	err = getntasks();
	if (err != nil)
		return err;
	spawn taskmon(nprep, nsched, nseq);
	return nil;
}

taskcount(): int
{
	return ntasks;
}

opendata(nil: string,
		nil: int,
		nil: chan of Readreq,
		nil: chan of Writereq,
		nil: chan of int): string
{
	return "permission denied";
}

start(id: string,
	tries:	int,
	spec: ref Clientspec,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	if(tries >= maxretries) {
		log(sys->sprint("task id %s: too many tries", id));
		taskfailed(id);
		return (Nomore, nil);
	}

	if (!specok(spec))
		return (Error, "not supported");
	attrs := "";
	for(i := 0; i < len spec.attrs.a; i++)
		attrs += sys->sprint("%q %q ", spec.attrs.a[i].t0, spec.attrs.a[i].t1);

	if (id == nil) {
		id = <-nexttask;
		if (id == nil)
			return (Nomore, nil);
	}

	runid := <-getuniqid;
	taskcmds := list of {
		"echo"::"-n"::jobtype::nil,
		"runtask"::id::runid::attrs::nil,
		"submit"::id::runid::nil
	};
	endcmd := "endtask"::id::runid::nil;
	spawn taskproc(id, taskcmds, endcmd, read, write, finish);
	return (Started, id);
}

reconnect(id: string,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	runid := <-getuniqid;
	spawn taskproc(id,
		("submit"::id::runid::nil) :: nil,
		"endtask"::id::runid::nil,
		 read,
		write, 
		finish
	);
	return (Started, nil);
}

state(): string
{
	r := chan of string;
	getstate <-= r;
	return <-r;
}

taskfailed(id: string)
{
	err := runscript("failedtask" :: id :: nil, devnull(), logfd());
	if (err != nil)
		log(sys->sprint("failedtask %s failed: %#q", id, err));
}

complete()
{
	if(ctxt.get("fn-complete") != nil)
		runscript("complete" :: nil, devnull(), logfd());
	log("complete");
}

quit()
{
	# shutdown taskmon
	log("quit");
	getstate <-= nil;
}

preptask(statc: chan of string, id: int)
{
	sync := chan of int;
	spawn scriptproc(sync, statc, "mktask"::string id::nil, devnull(), logfd());
	<-sync;
}

taskmon(nprep, nsched, nseq: int)
{
	tname := string nsched;
	if (nsched >= ntasks)
		tname = nil;

	waitlist: list of (int, chan of int);

	prepres := chan of string;
	pending := 0;
	if (nprep - nsched < pendtasks && nprep < ntasks) {
		preptask(prepres, nprep);
		pending = 1;
	}

	for (;;) alt {
	status := <-prepres =>
		pending = 0;
		waitlist = wakeup(waitlist,nprep);
		if (status != nil) {
			sys->fprint(stderr(), "mktask %d failed: %s\n", nprep, status);
			nprep++;
			continue;
		}
		nprep++;
		if (nprep - nsched < pendtasks && nprep < ntasks) {
			preptask(prepres, nprep);
			pending = 1;
		}
		
	nexttask <-= tname =>
		if (tname == nil)
			continue;
		nsched++;
		tname = string nsched;
		if (nsched >= ntasks)
			tname = nil;
		if (nprep - nsched < pendtasks && !pending && nprep < ntasks) {
			preptask(prepres, nprep);
			pending = 1;
		}

	getuniqid <-= string nseq =>
		nseq++;

	state := <-getstate =>
		if (state == nil) {	# quit
			# XXX is this safe w.r.t taskproc()
			if (pending)
				# wait for preptask
				<-prepres;
			return;
		}
		state <-= sys->sprint("%11d %11d %11d ", nprep, nsched, nseq);

	(id, ready) := <-waitfortask =>
		t := int id;
		if (t < nprep) {
			# we do not know if mktask failed
			ready <-= 1;
			continue;
		}
		waitlist = (t, ready)::waitlist;
	}
}

wakeup(wl: list of (int, chan of int), id: int): list of (int, chan of int)
{
	newl: list of (int, chan of int);
	for (; wl != nil; wl = tl wl) {
		(wid, wr) := hd wl;
		if (wid == id) {
			wr <-= 1;
			continue;
		}
		newl = hd wl :: newl;
	}
	return newl;
}

# assumed that last taskcmd is restartable on disconnect
#
taskproc(id: string,
	taskcmds: list of list of string,
	endcmd: list of string,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string))
{
	go := chan of int;
	waitfortask <-= (id, go);
	<-go;
	io := startio(read, write);
	finack: chan of string;
	first := 0;

taskloop:
	for (cl := taskcmds; cl != nil; cl = tl cl) {
		lastcmd := (tl cl == nil);
		res := chan of string;
		sync := chan of int;
		spawn scriptproc(sync, res, hd cl, io.stdin, io.stdout);
		<-sync;
		for (;;) alt {
		(first, nil, finack) = <-finish =>
			endio(io);
			status := <-res;
			if(status != nil)
				log(sys->sprint("task %s: %#q failed: %s", id, hd hd taskcmds, status));
			if (status != nil) {
				if (lastcmd)	# hangup is ok for last cmd
					finack <-= "disconnected";
				else
					finack <-= "error:"+status;
				return;
			} else if (!lastcmd) {
				finack <-= "premature eof";
				return;
			}
			break taskloop;

		status := <-res =>
			if (status != nil) {
				log(sys->sprint("task %s: %#q failed: %s", id, hd hd taskcmds, status));
				hangupio(io);
				(nil, nil, finack) = <-finish;
				endio(io);
				finack <-= "error:"+status;
				return;
			}
			if (lastcmd) {
				# done all cmds but not seen finish yet
				hangupio(io);
				(first, nil, finack) = <-finish;
				endio(io);
				break taskloop;
			}
			continue taskloop;
		}
	}
	err := "";
	if (first) {
		err = runscript(endcmd, devnull(), logfd());
		if (err != nil) {
			log(sys->sprint("task %s: %s failed: %#q", id, str->quoted(endcmd), err));
			err = "error:"+err;
		}
	}
	finack <-= err;
}

specok(spec: ref Clientspec): int
{
	a := spec.attrs.a;
	for(i := 0; i < len a; i++)
		if(prefix(a[i].t0, "jobtype") && a[i].t1 == jobtype)
			return 1;
	return 0;
}

# sanity check: make sure we have necessary scripts for the job
checkjobfns(): string
{
	fns := list of {
		"mkjob",		# mkjob jobargs...
		"mktask",		# mktask taskid
		"runtask",		# runtask taskid runid
		"submit",		# submit taskid runid
		"endtask",		# endtask taskid runid
		"failedtask",	# failedtask taskid
	};
	for(; fns != nil; fns = tl fns)
		if(ctxt.get("fn-" + hd fns) == nil)
			return "job function " + hd fns + " is not defined";
	return nil;
}

getntasks(): string
{
	# mkjob script should create ntasks file
	fd := sys->open(workdir+"/ntasks", Sys->OREAD);
	if (fd == nil)
		return sys->sprint("mkjob failed to report ntasks: %r");
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if (n <= 0)
		return sys->sprint("failed to read ntasks: %r");
	ntasks = int string buf[:n];
	if (ntasks <= 0)
		return "mkjob reported no tasks";
	return nil;
}

runscript(argv: list of string, stdin, stdout: ref Sys->FD): string
{
	sync := chan of int;
	res := chan of string;
	spawn scriptproc(sync, res, argv, stdin, stdout);
	<-sync;
	return <-res;
}

scriptproc(sync: chan of int, rc: chan of string, argv: list of string,
			stdin, stdout: ref Sys->FD)
{
	sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
	if (stdin != nil)
		sys->dup(stdin.fd, 0);
	if (stdout != nil)
		sys->dup(stdout.fd, 1);
	stdin = nil;
	stdout = nil;
	if (sys->chdir(workdir) != 0) {
		rc <-= sys->sprint("cannot chdir to %s: %r", workdir);
		return;
	}
	sys->pctl(Sys->NEWFD, 0::1::2::nil);
	ctxtlock <-= 1;
	nctxt := ctxt.copy(1);
	<-ctxtlock;
	sync <-= sys->pctl(0, nil);
	rc <-= run(nctxt, argv);
}

Scriptio: adt {
	stdin: ref Sys->FD;		# pipe ends to dup to spawned script fds
	stdout: ref Sys->FD;
	quit: chan of int;
};

startio(read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int)): ref Scriptio
{
	stdin := array[2] of ref Sys->FD;
	stdout := array[2] of ref Sys->FD;

	sys->pipe(stdin);
	sys->pipe(stdout);

	qc := chan[2] of int;

	spawn readproc(stdout[1], read, qc);
	spawn writeproc(stdin[1], write, qc);

	return ref Scriptio(stdin[0], stdout[0], qc);
}

hangupio(io: ref Scriptio)
{
	io.stdin = nil;
	io.stdout = nil;
}

endio(io: ref Scriptio)
{
	io.stdin = nil;
	io.stdout = nil;
	io.quit <-= 1;
	io.quit <-= 1;
}

readproc(fd: ref Sys->FD, read: chan of (int, chan of array of byte, chan of int), quit: chan of int)
{
	buf: array of byte;
	for (;;) alt {
	<-quit =>
		return;
	(n, r, flushc) := <-read =>
		if(len buf > 0){
			alt{
			flushc <-= 1 =>
				if(n > len buf)
					n = len buf;
				r <-= buf[0:n];
				buf = buf[n:];
			* =>
				r <-= nil;		# flushed
			}
		}else{
#			if(n > Sys->ATOMICIO)
#				n = Sys->ATOMICIO;
			buf = array[n] of byte;
			n = sys->read(fd, buf, n);
			if(n < 0)
				n = 0;
			buf = buf[0:n];
			alt{
			flushc <-= 1 =>
				if(n < 0)
					n = 0;
				r <-= buf;
				buf = nil;
			* =>
				r <-= nil;
			}
		}
	}
}

writeproc(fd: ref Sys->FD, write: chan of (array of byte, chan of string, chan of int), quit: chan of int)
{
	for (;;) alt {
	<-quit =>
		return;
	(buf, r, flushc) := <-write =>
		# can get write on closed pipe exception
		n := len buf;
		{
			n = sys->write(fd, buf, n);
		} exception {
		"write on closed pipe" =>
			n = len buf;			# XXX ignore prematurely exiting command for the time being.
		}
		alt{
		flushc <-= 1 =>
			if(n < len buf){
				e := "";
				if(n < 0){
					if((e = sys->sprint("%r")) == "flushed")
						e = "flush";		# hmm.
				}else
					e = "short write (" + string n + "/" + string len buf + ")";
				r <-= e;
			}else
				r <-= nil;
		* =>
			r <-= "flushed";
		}
	}
}

remove(path: string): string
{
	(ok, info) := sys->stat(path);
	if(ok == -1)
		return sys->sprint("cannot stat %s: %r", path);
	if((info.mode & Sys->DMDIR) == 0){
		if(sys->remove(path) == -1)
			return sys->sprint("cannot remove %s: %r", path);
		return nil;
	}
	(d, n) := readdir->init(path, Readdir->NONE|Readdir->COMPACT);
	for(i := 0; i < n; i++)
		if((e := remove(path + "/" + d[i].name)) != nil)
			return e;
	return remove(path);
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

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

devnull(): ref Sys->FD
{
	return sys->open("#c/null", Sys->ORDWR);
}

logfd(): ref Sys->FD
{
	if (verbose)
		return stderr();
	return devnull();
}

kill(pid: int)
{
	sys->fprint(sys->open("#p/"+string pid+"/ctl", Sys->OWRITE), "kill");
}

debug(msg: string)
{
	if (verbose)
		sys->print("debug %s\n", msg);
}

log(msg: string)
{
	sys->print("log %s\n", msg);
}

run(shctxt: ref Context, argv: list of string): string
{
	l := sh->stringlist2list(argv);
	{
		return shctxt.run(l, 0);
	} exception e {
	"fail:*" =>
		return e[5:];
	}
}
