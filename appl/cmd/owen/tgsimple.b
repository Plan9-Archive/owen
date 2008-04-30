implement TGsimple, Taskgenmod;
include "sys.m";
	sys: Sys;
include "readdir.m";
	readdir: Readdir;
include "string.m";
	str: String;
include "attributes.m";
include "arg.m";
include "taskgenerator.m";
	Taskgenreq, Clientspec, Readreq, Writereq, Finishreq,
	Nomore, Error, Started: import Taskgenerator;
include "tgsimple.m";
include "tgself.m";

params: Params;
jobargs: list of string;

ntasks: int;
preptask: chan of int;
getuniq: chan of int;
stopuniq: chan of int;
puttask: chan of (int, ref Sys->FD, chan of int);
needkick: chan of chan of int;
kick: chan of int;

nstarted := 0;
rootdir: string;
workdir: string;
mod: Simplegen;

init(p: Params, job: list of string, root, work, state: string, kickt: chan of int,
		gen: Simplegen): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgself := load TGself TGself->PATH;
	if(tgself == nil)
		return (nil, sys->sprint("cannot load %s: %r", TGself->PATH));
	if(job == nil)
		return (nil, "no job type");

	params = p;
	rootdir = root;
	workdir = work;
	jobargs = job;
	kick = kickt;
	mod = gen;
	sgen := load Taskgenmod "$self";
	if(sgen == nil)
		return (nil, sys->sprint("cannot self as Taskgenmod: %r"));
	return tgself->init(state, nil, sgen);
}

tginit(state: string, nil: list of string): string
{
	sys = load Sys Sys->PATH;
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		return sys->sprint("cannot load %s: %r", Readdir->PATH);
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load %s: %r", String->PATH);
	sys->pctl(Sys->FORKNS, nil);

	puttask = chan of (int, ref Sys->FD, chan of int);
    
	modstate: string;
	if(state != nil){
		(nstarted, modstate) = str->toint(state, 10);
		modstate = modstate[1:];		# skip space separator
	}

	e: string;
	(ntasks, e) = mod->simpleinit(rootdir, workdir, modstate);
	if(e != nil){
		if(state == nil)
			remove(workdir);
		return e;
	}
	spawn putproc();

	if(state != nil){
		checkoldtasks();
	}

	preptask = chan[params.pendtasks] of int;
	spawn prepare(nstarted, taskc := chan of int);
	spawn kicker(taskc, preptask, needkick = chan of chan of int);
	getuniq = chan of int;
	stopuniq = chan of int;
	spawn mkuniq(stopuniq, getuniq);
	debug("created ok");
	return nil;
}


# kick scheduler when it's asked for a task and we didn't have
# one, but now we do.
kicker(taskc, preptask: chan of int, needkick: chan of chan of int)
{
	kickc: chan of int;
	sent := 0;
	for(;;){
		alt{
		n := <-taskc =>
	sendit:
			for(;;)alt{
			preptask <-= n =>
				sent = 1;
				break sendit;
			kickc = <-needkick =>
				if(kickc == nil)	
					exit;
			}
		kickc = <-needkick =>
			if(kickc == nil)
				exit;
		}
		if(kickc != nil && sent){
			alt{kickc <-= 1 =>; * =>;}
			kickc = nil;
			sent = 0;
		}
	}
}

taskcount(): int
{
	return ntasks;
}

opendata(user: string,
	mode: int,
	read: chan of Readreq,
	write: chan of Writereq,
	clunk: chan of int): string
{
	return mod->opendata(user, mode, read, write, clunk);
}

state(): string
{
	return string nstarted + " " + mod->state();
}

start(id: string,
	tries:	int,
	spec: ref Clientspec,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	n: int;
	debug(sys->sprint("start %q", id));
	if (!specok(spec)){
		return (Error, "not supported");
	}
	debug("spec is ok");
	if(tries >= params.maxretries){
		log(sys->sprint("task id %s: too many tries", id));
		if(params.keepfailed)
			rename(taskdir(int id), id+".failed");
		else
			remove(taskdir(int id));
		return (Nomore, "too many tries");
	}

	if(id != nil)
		n = int id;
	else {
		alt{
		n = <-preptask =>
			if(n == -1)
				return (Nomore, "no more tasks");
		* =>
			needkick <-= kick;
			# XXX can't block starting a task yet.
			return (Error, "no tasks currently available");
		}
		nstarted = n + 1;
	}
	return starttask(n, 0, read, write, finish);
}

reconnect(id: string,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	return starttask(int id, 1, read, write, finish);
}

complete()
{
	debug("tgsimple: complete");
	puttask <-= (0, nil, nil);
}

quit()
{
	debug("tgsimple: quit");
	puttask <-= (-1, nil, nil);
	needkick <-= nil;
	stopuniq <-= 1;
}

starttask(n: int, reconnect: int,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	d := taskdir(n);
	pfd := sys->open(d+"/param", Sys->OREAD);
	if(pfd == nil){
		log(sys->sprint("cannot open %q: %r", d+"/param"));
		# this can happen if the task has already been successfully completed
		# (and the task directory therefore removed) but the scheduler doesn't
		# yet know this. for the rarer case of a param file being externally
		# removed, the maxretries parameter should deal with it.
		return (Error, "param file disappeared");
	}
	rf := d+"/result"+string <-getuniq;
	rfd := sys->create(rf, Sys->OWRITE, 8r666);
	if(rfd == nil){
		log(sys->sprint("cannot create %q: %r", rf));
		return (Nomore, "cannot create result file");			# XXX what happens when fs fills up?
	}
	spawn taskproc(n, rf, pfd, rfd, reconnect, read, write, finish);
	return (Started, string n);
}

specok(spec: ref Clientspec): int
{
	a := spec.attrs.a;
	for(i := 0; i < len a; i++)
		if(prefix(a[i].t0, "jobtype") && a[i].t1 == hd jobargs)
			return 1;
	return 0;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

taskproc(task: int,
	rf: string,
	pfd,
	rfd: ref Sys->FD,
	reconnect: int,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string))
{
	inheader := 1;
	sentall := reconnect;
	for(;;)alt{
	(n, r, flushc) := <-read =>
		alt{
		flushc <-= 1 =>
			buf: array of byte;
			if(reconnect)
				buf = array[0] of byte;
			else if(inheader){
				buf = array of byte str->quoted(jobargs);
				inheader = 0;
			}else{
				buf = array[n] of byte;
				n = sys->read(pfd, buf, n);
				if(n <= 0){
					n = 0;
					sentall = 1;
				}
				if(n < len buf)
					buf = buf[0:n];
			}
			r <-= buf;
		* =>
			r <-= nil;		# flushed
		}
	(buf, r, flushc) := <-write =>
		alt{
		flushc <-= 1 =>
			n := sys->write(rfd, buf, len buf);
			if(n < len buf){
				# XXX e.g. disk full... what do we do?
				debug(sys->sprint("task result-writefail %d %d %q", task, len buf, sys->sprint("%r")));
				r <-= sys->sprint("write result failed: %r");
			}else{
				debug(sys->sprint("task result-write %d %d", task, len buf));
				r <-= nil;
			}
		* =>
			r <-= "flushed";
		}
	(first, nil, r) := <-finish =>
		debug(sys->sprint("task finish %d %d", task, first));
		if(first){
			if(!sentall && sys->read(pfd, array[1] of byte, 1) > 0){
				r <-= "parameters not read";
				exit;
			}
			sys->seek(rfd, big 0, Sys->SEEKSTART);
			e := mod->verify(task, rfd);
			if(e != nil){
				r <-= e;
				exit;
			}
		}
		if(first){
			sys->seek(rfd, big 0, Sys->SEEKSTART);
			rename(rf, "result");
			rename(taskdir(task), string task + ".done");
			rf = taskdir(task)+".done/result";
			rfd = sys->open(rf, Sys->OREAD);
			if(rfd == nil){
				log(sys->sprint("cannot re-open %q file (task %d): %r", rf, task));
				rename(taskdir(task)+".done", string task+".strange");
				exit;
			}
			reply := chan of int;
			# XXX we can block indefinitely here; check that this doesn't matter.
			puttask <-= (task, rfd, reply);
			<-reply;
		}
		r <-= nil;
		rfd = pfd = nil;
		# on windows the remove will fail until the last instance due to open files.
		if(!params.keepall)
			remove(taskdir(task)+".done");
		if(!params.keepfailed)
			remove(taskdir(task)+".failed");
		exit;
	}
}

# look for any tasks ending in ".done" and put them.
checkoldtasks()
{
	(d, n) := readdir->init(workdir, Readdir->NONE|Readdir->COMPACT);
	l: list of int;
	for(i := 0; i < n; i++)
		if(suffix(d[i].name, ".done"))
			l = int d[i].name :: l;
	if(l != nil)
		spawn putoldtasks(l);
}

suffix(s, suff: string): int
{
	return len s > len suff && s[len s - len suff:] == suff;
}

putoldtasks(l: list of int)
{
	reply := chan of int;
	for(; l != nil; l = tl l){
		d := taskdir(hd l)+".done";
		fd := sys->open(d+"/result", Sys->OREAD);
		if(fd == nil)
			log(sys->sprint("cannot open old result %q: %r", d+"/result"));
		else{
			puttask <-= (hd l, fd, reply);
			<-reply;
			if(!params.keepall)
				remove(d+".done");
		}
	}
}

putproc()
{
	while(((task, fd, reply) := <-puttask).t2 != nil){
		debug("puttask "+string task);
		mod->put(task, fd);
		debug("puttask "+string task+" done");
		fd = nil;
		reply <-= 1;
	}
	if(task != -1){
		debug("all puttasks completed");
		mod->complete();
		<-puttask;	# XXX are we totally sure that nothing other than quit() can send on puttask?
	}
	mod->quit();
	if(!params.keepall && !params.keepfailed)
		remove(workdir);
}

# prepare tasks; when starting again, we'll re-prepare
# some tasks, but we don't mind too much.
prepare(n: int, taskc: chan of int)
{
	for(;;){
		d := taskdir(n);
		# if task has already been made, use that.
		if(sys->stat(d+"/param").t0 != -1){
			taskc <-= n++;
			continue;
		}
		mkdir(d);
		remove(d+"/partial");
		f := d+"/partial";
		fd := sys->create(f, Sys->OWRITE, 8r666);
		if(fd == nil){
			log(sys->sprint("cannot create %q: %r", f));
			break;
		}
		debug("create "+f);
		if(mod->get(fd) == -1){
			fd = nil;
			remove(d);
			break;
		}
		debug("prepared "+string n);
		fd = nil;
		taskc <-= n++;
	}
	taskc <-= -1;
}

# XXX could be more sophisticated to try to avoid huge directories.
taskdir(n: int): string
{
	return workdir+"/"+string n;
}

mkdir(path: string): string
{
	debug("mkdir "+path);
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
	if (fd == nil)
		return sys->sprint("cannot mkdir %s: %r", path);
	return nil;
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

rename(f1, name: string): int
{
	d := Sys->nulldir;
	d.name = name;
	r := sys->wstat(f1, d);
	if(r == -1)
		log(sys->sprint("cannot rename %q to %q: %r\n", f1, name));
	return r;
}

mkuniq(stop, c: chan of int)
{
	n := 0;
	for(;;){
		alt{
		c <-= n++ =>
			;
		<-stop =>
			exit;
		}
	}
}

debug(msg: string)
{
	if (params.verbose)
		sys->print("%s\n", msg);
}

log(msg: string)
{
	sys->print("%s\n", msg);
}
