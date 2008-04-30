implement Testclient;
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
include "arg.m";
include "rand.m";
	rand: Rand;

Testclient: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Task: adt {
	srvid: string;
	ms:	int;
	resultdata: int;
	mode: int;
};

verbose := 0;
noauth := 0;
wbuf := array[8192] of byte;
MAXRECONNECT: con 10;		# something under 3 minutes

# usage: testclient addr nconns
init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sh = load Sh Sh->PATH;
	rand = load Rand Rand->PATH;
	rand->init(sys->millisec());
	sh->initialise();

	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("usage: testclient [-Av] addr nconns");
	while((opt := arg->opt()) != 0){
		case opt {
		'v' =>
			verbose = 1;
		'A' =>
			noauth = 1;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(len argv != 2)
		arg->usage();
	addr := hd argv;
	n := int hd tl argv;
	sync := chan of int;
	for(i := 0; i < n; i++){
		spawn conn(i, addr, nil, 1, sync);
		<-sync;
	}
	sys->print("started %d clients\n", n);
}

reads(fd: ref Sys->FD): string
{
	buf := array[200] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		sys->print("error on read: %r\n");
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

conn(id: int, addr: string, t: ref Task, maxreconnect: int, sync: chan of int)
{
	sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
	argv := addr :: "/n/remote" :: nil;
	if(noauth)
		argv = "-A" :: argv;
	tries := 0;
	backoff := 1000 + rand->rand(500) - 250;
	for(;;){
		if(sh->run(nil, "mount" :: argv) == nil)
			break;
		if(++tries >= maxreconnect){
			sys->print("%d: mount failed in client after %d attempts\n", id, tries);
			sync <-= -1;
			exit;
		}
		sys->sleep(backoff);
		backoff = backoff*3/2;
	}
	sync <-= 0;
	if(verbose)
		sys->print("%d: mounted scheduler\n", id);
	sys->fprint(sys->open("/n/remote/nodeattrs", Sys->OWRITE), "cpu '386 %d'", sys->pctl(0,nil));
	stopfd := sys->open("/n/remote/stoptask", Sys->OREAD);
	if(stopfd == nil){
		sys->print("cannot open stoptask: %r\n");
		exit;
	}
	stopc := chan of int;
	spawn taskstopproc(id, stopfd, stopc);
	stoppid := <-stopc;

	if(t != nil){
		reconnecttask(id, t);
		t = nil;
	}
Opentask:
	for(;;){
		fd := sys->open("/n/remote/task", Sys->ORDWR);
		if(fd == nil)
			break;
		t = ref Task;
		t.srvid = reads(fd);
		if(verbose)
			sys->print("%d: starting task %s\n", id, t.srvid);
		req := reads(fd);
		if(req == nil){
			if(verbose)
				sys->print("%d: eof on request, exiting\n", id);
			exit;
		}
		(n, toks) := sys->tokenize(req, " ");
		if(n != 4){
			sys->print("bad request format %#q\n", req);
			break;
		}
		toks = tl toks;
		t.ms = int hd toks; toks = tl toks;
		t.resultdata = int hd toks; toks = tl toks;
		t.mode = (hd toks)[0];
		if(verbose)
			sys->print("%d: request %#q\n", id, req);
		case t.mode {
		'g' =>
			# good
			if(sleep(t.ms, fd, t.srvid, stopc) != -1)
			if(writedata(fd, t) == -1){
				if(verbose)
					sys->print("%d: write data failed: %r\n", id);
				break Opentask;
			}
		'i' =>
			# immediate
			if(writedata(fd, t) == -1){
				if(verbose)
					sys->print("%d: write data failed: %r\n", id);
				break Opentask;
			}
		'c' =>
			# hang up forever
			if(verbose)
				sys->print("%d: client hanging up\n", id);
			<-chan of int;
		'w' =>
			# no data written
			sleep(t.ms, fd, t.srvid, stopc);
		'r' =>
			break Opentask;
		}
		fd = nil;
	}
	if(verbose)
		sys->print("%d: attempting reconnect\n", id);
	kill(stoppid, "kill");
	spawn conn(id, addr, t, MAXRECONNECT, chan[1] of int);
	exit;
}

reconnecttask(id: int, t: ref Task)
{
	if(verbose)
		sys->print("%d: trying to reconnect to task %q\n", id, t.srvid);
	fd := sys->open("/n/remote/reconnect", Sys->ORDWR);
	if(fd == nil){
		sys->print("%d: cannot open /n/remote/reconnect: %r\n", id);
		return;
	}
	if(sys->fprint(fd, "%s", t.srvid) == -1){
		sys->print("%d: cannot reconnect to task %q: %r\n", id, t.srvid);
		return;
	}
	if(sys->fprint(fd, "reconnect") == -1){
		sys->print("%d: (reconnect) write clientid failed: %r\n", id);
		return;
	}
	if(writedata(fd, t) == -1){
		sys->print("%d: (reconnect) write data failed: %r\n", id);
		return;
	}
	if(verbose)
		sys->print("%d: successfully reconnected to task %q\n", id, t.srvid);
}

writedata(fd: ref Sys->FD, t: ref Task): int
{
	for(nb := 0; nb + len wbuf <= t.resultdata; nb += len wbuf)
		if(sys->write(fd, wbuf, len wbuf) < len wbuf){
			if(sys->sprint("%r") == "task has completed")
				return 0;
			return -1;
		}
	if(nb < t.resultdata)
		if(sys->write(fd, wbuf, t.resultdata - nb) < t.resultdata - nb){
			if(sys->sprint("%r") == "task has completed")
				return 0;
			return -1;
		}
	return 0;
}

sleep(ms: int, fd: ref Sys->FD, srvid: string, stopc: chan of int): int
{
	sync := chan of int;
	spawn sleeper(ms, sync);
	pid := <-sync;
	if(sys->fprint(fd, "%d %s", pid, srvid) <= 0)
		sys->print("clientid write error: %r\n");
	for(;;){
		alt{
		kpid := <-stopc =>
			if(kpid != pid)
				continue;
			kill(kpid, "kill");
			return -1;
		<-sync =>
			return 0;
		}
	}
}

sleeper(ms: int, sync: chan of int)
{
	sync <-= sys->pctl(0, nil);
	sys->sleep(ms);
	sync <-= 0;
}

taskstopproc(id: int, stopfd: ref Sys->FD, stopc: chan of int)
{
	stopc <-= sys->pctl(0, nil);
	while((pid := reads(stopfd)) != nil){
		if(verbose)
			sys->print("%d: asked to kill %s\n", id, pid);
		stopc <-= int pid;
	}
	if(verbose)
		sys->print("eof on taskstop\n");
}

kill(pid: int, note: string): int
{
	fd := sys->open("#p/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}
