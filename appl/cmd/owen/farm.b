implement Farm;
include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rand: Rand;
include "string.m";
	str: String;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "sh.m";
	sh: Sh;
include "arg.m";

Farm: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# a whole packet - could use external storage for this if we thought
# task param/result data might get huge.
Packet: adt {
	data: list of array of byte;
};

EIO: con "i/o on hungup channel";
SCHEDDIR: con "/n/remote";
MAXBACKOFF: con 2 * 60 * 1000;
Empty: con Packet(nil);

Down, Quit,
Ok, Again, Error: con iota;

noauth: int;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKNS, nil);

	rand = load Rand Rand->PATH;
	if (rand == nil)
		badmodule(Rand->PATH);
	rand->init(sys->millisec());
	str = load String String->PATH;
	if (str == nil)
		badmodule(String->PATH);
	sh = load Sh Sh->PATH;
	if(sh == nil)
		badmodule(Sh->PATH);
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		badmodule(Bufio->PATH);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		badmodule(Arg->PATH);
	descr := "";
	verbose := 0;
	arg->init(argv);
	arg->setusage("farm [-A] [-d description] schedaddr jobtype");
	while((opt := arg->opt()) != 0){
		case opt {
		'd' =>
			descr = arg->earg();
		'A' =>
			noauth = 1;
		'v' =>
			verbose = 1;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(len argv < 2)
		arg->usage();
	schedaddr := hd argv;
	jobargs := tl argv;
	if(verbose){
		jobargs = "-v" :: jobargs;
		loginit();
	}

	sysname := readfile("/dev/sysname");
	if(sysname != nil)
		sysname += " (J)";
	if((e := mountsched1(schedaddr, sysname)) != nil)
		error(sys->sprint("cannot initially mount %q: %s", schedaddr, e));
	(ctlfd, jobdir) := newjob();
	if(ctlfd == nil)
		error("cannot make job: "+jobdir);
	if(sys->fprint(ctlfd, "load split %s", str->quoted(jobargs)) == -1)
		error(sys->sprint("cannot load job: %r"));
	if(sys->fprint(ctlfd, "start") == -1)
		error(sys->sprint("cannot start job: %r"));
	jobid := readfile(jobdir+"/id");
	if(jobid == nil)
		error("cannot read "+jobdir+"/id");

	sync := chan of int;
	taskc := chan of (Packet, chan of int);
	spawn fd2tasks(sync, sys->fildes(0), taskc);
	f2tpid := <-sync;

	for(;;){
		if(!mounted()){
			mountsched(schedaddr, sysname);
			ctlfd = nil;
			if(readfile(jobdir+"/id") != jobid)
				error("job "+jobid+" has disappeared");
		}
		rfd := sys->open(jobdir+"/data", Sys->OREAD);
		wfd := sys->open(jobdir+"/data", Sys->OWRITE);
		if(rfd == nil || wfd == nil){
			if((e = sys->sprint("%r")) == EIO)
				continue;
			kill(f2tpid);
			error(sys->sprint("cannot open %q: %r", jobdir+"/data"));
		}
		down := chan[2] of int;
		ackresult := chan of int;
		spawn tasks2sched(taskc, wfd, ackresult, down);
		spawn sched2fd(sync, rfd, ackresult, sys->fildes(1), down);
		s2fpid := <-sync;
		w := <-down;
		down <-= w;
log(sys->sprint("down (%d)", w));
		kill(s2fpid);
		if(w == Quit)
			break;
		if(mounted()){
log("is still mounted so must be error");
			break;
		}
	}
	kill(f2tpid);
	if(ctlfd == nil)
		ctlfd = sys->open(jobdir+"/ctl", Sys->OWRITE);
	if(ctlfd != nil){
		if(sys->fprint(ctlfd, "delete") == -1)
			error(sys->sprint("cannot delete job %q: %r", jobid));
	}
	if(logch != nil)
		logch <-= nil;
}

fd2tasks(sync: chan of int, fd: ref Sys->FD, taskc: chan of (Packet, chan of int))
{
	sync <-= sys->pctl(0, nil);
	iob := bufio->fopen(fd, Sys->OREAD);
	reply := chan of int;
getpacket:
	while((s := iob.gets('\n')) != nil){
		d := array of byte s;
		p := Packet(array of byte sys->sprint("data %d\n", len d) :: d :: nil);
		for(;;){
			taskc <-= (p, reply);
			case <-reply {
			Ok =>
				continue getpacket;
			Again =>
				;
			Error =>
				exit;
			}
		}
	}
	taskc <-= (Empty, nil);
}

fd2tasks1(sync: chan of int, fd: ref Sys->FD, taskc: chan of (Packet, chan of int))
{
	sync <-= sys->pctl(0, nil);
	iob := bufio->fopen(fd, Sys->OREAD);
	reply := chan of int;
getpacket:
	for(;;){
		(p, err) := readpacket(iob);
		if(p.data == nil){
			if(err != nil)
				sys->fprint(stderr(), "farm: error on input: %s", err);
			break;
		}
		for(;;){
			taskc <-= (p, reply);
			case <-reply {
			Ok =>
				continue getpacket;
			Again =>
				;
			Error =>
				exit;
			}
		}
	}
	taskc <-= (Empty, nil);
}

tasks2sched(taskc: chan of (Packet, chan of int), 
	wfd: ref Sys->FD,
	ackresult: chan of int, down: chan of int)
{
loop:
	for(;;) alt{
	w := <-down =>
		if(w == Quit){
log("write not coming back");
			write(wfd, array[0] of byte);			# tell scheduler we're not coming back.
			down <-= Quit;
			exit;
		}
log("tasks2sched got down");
		break loop;
	n := <-ackresult =>
log(sys->sprint("acking result %d", n));
		if(write(wfd, array of byte ("got "+string n+"\n")) == -1)
			break loop;
	(task, reply) := <-taskc =>
		if(reply == nil){
			write(wfd, array of byte "eof\n");
			break;
		}
log(sys->sprint("got task (%d bytes)", len hd task.data));
		
		for(; task.data != nil; task.data = tl task.data){
			if(write(wfd, hd task.data) == -1){
				reply <-= Again;
				break loop;
			}
		}
log("written task");
		reply <-= Ok;
	}
log("got eof on tasks");
	down <-= Down;
}

readpacket(iob: ref Iobuf): (Packet, string)
{
	l, r: list of array of byte;
	header := iob.gets('\n');
	if(header == nil)
		return (Empty, nil);
	if(!prefix(header, "data "))
		return (Empty, sys->sprint("invalid record %#q", header));
	nr := int header[len "data ":];
	l = array of byte header :: l;
log(sys->sprint("header %#q, %d bytes to come", cleanstr(header), nr));
	while(nr > 0){
		n := nr;
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		buf := array[n] of byte;
		if((n = iob.read(buf, n)) <= 0)
			return (Empty, sys->sprint("premature eof (expected %d more)", nr));
		l = buf :: l;
		nr -= n;
	}
	for(; l != nil; l = tl l)
		r = hd l :: r;

s := "";
for(l = r; l != nil; l = tl l)
	s += sys->sprint(", %#q", cleanstr(string hd l));
log(sys->sprint("got packet %s", s));
tot := 0;
for(l = tl r; l != nil; l = tl l)
tot += len hd l;
log(sys->sprint("actual length %d", tot));
	return (Packet(r), header);
}

sched2fd(sync: chan of int, rfd: ref Sys->FD, ackresult: chan of int, fd: ref Sys->FD, down: chan of int)
{
	sync <-= sys->pctl(0, nil);
	iob := bufio->fopen(rfd, Sys->OREAD);
	for(;;){
		(p, e) := readpacket(iob);
		if(p.data == nil){
log(sys->sprint("sched2fd got nil (err %q)", e));
			if(e == nil && mounted()){
log("still mounted, so genuine eof");
				down <-= Quit;
			}else
				down <-= Down;
			exit;
		}
log("sched2fd got packet");
		(n, toks) := sys->tokenize(e, " ");
		if(n != 3){
			sys->fprint(stderr(), "farm: bad result packet %#q\n", e);
			down <-= Quit;
			exit;
		}
		ackresult <-= int hd tl tl toks;
		{
			for(; p.data != nil; p.data = tl p.data){
#				log(sys->sprint("out: %#q", cleanstr(string hd p.data)));
				if(sys->write(fd, hd p.data, len hd p.data) == -1){
					sys->fprint(stderr(), "farm: write error: %r\n");
					down <-= Quit;
				}
			}
		} exception {
		"write on closed pipe" =>
			down <-= Quit;
			exit;
		}
	}
}

crackheader(d: array of byte): int
{
	for(i := 0; i < len d; i++)
		if(d[i] == byte ' ')
			break;
	if(string d[0:i] != "task")
		return -1;
	i++;
	if(i >= len d || d[i] < byte '0' || d[i] > byte '9')
		return -1;
	return int string d[i:];
}

write(wfd: ref Sys->FD, d: array of byte): int
{
	if(sys->write(wfd, d, len d) == len d)
		return 0;
	if((e := sys->sprint("%r")) != EIO)
		sys->fprint(stderr(), "farm: error writing data: %s\n", e);
	return -1;
}

# is scheduler still mounted? (quick and dirty test)
mounted(): int
{
	return sys->stat(SCHEDDIR+"/nodename").t0 != -1;
}

mountsched(addr: string, sysname: string)
{
	backoff := 0;
	for(;;){
		if(mountsched1(addr, sysname) == nil)
			return;
		if(backoff == 0)
			backoff = 1000 + rand->rand(500) - 250;
		else if(backoff < MAXBACKOFF)
			backoff = backoff * 3 / 2;
		# debug(sys->sprint("backoff %dms (%s)", backoff, e));
		sys->sleep(backoff);
	}
}

mountsched1(addr: string, sysname: string): string
{
	sys->unmount(nil, SCHEDDIR);
	argv := addr :: SCHEDDIR :: nil;
	if(noauth)
		argv = "-A" :: argv;
	if((e := sh->run(nil, "mount" :: argv)) == nil) {
		fd := sys->open(SCHEDDIR+"/nodename", sys->OWRITE);
		if(fd == nil)
			return sys->sprint("cannot open nodename: %r");
		if (sysname != nil)
			sys->fprint(fd, "%s", sysname);
		return nil;
	}
	return e;
}

newjob(): (ref Sys->FD, string)
{
	buf := array[20] of byte;
	fd := sys->open(SCHEDDIR+"/admin/clone", Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", SCHEDDIR+"/admin/clone"));
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, "cannot read job id");
	return (fd, SCHEDDIR+"/admin/"+string buf[0:n]);
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

error(e: string)
{
	sys->fprint(stderr(), "farm: %s\n", e);
	if(logch != nil)
		logch <-= nil;
	raise "fail:error";
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

badmodule(p: string)
{
	sys->fprint(stderr(), "farm: cannot load %s: %r\n", p);
	raise "fail:bad module";
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

kill(pid: int)
{
	if ((fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE)) != nil)
		sys->fprint(fd, "kill");
	else
		log(sys->sprint("cannot kill %d: %r", pid));
}

cleanstr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			break;
	if(i == len s)
		return s;
	ns := s[0:i];
	for(; i < len s; i++){
		if(s[i] == '\n'){
			ns[len ns] = '\\';
			ns[len ns] = 'n';
		}else
			ns[len ns] = s[i];
	}
	return ns;
}

loginit()
{
	timefd = sys->open("/dev/time", Sys->OREAD);
	starttime = now();
	logch = chan of string;
	spawn logproc(sys->fildes(1));
}

# make sure log writes are serialised.
# XXX does each write need to be synchronous?
logproc(logfd: ref Sys->FD)
{
	sys->fprint(logfd, "%.10bd starttime %.10bd\n", now(), now() + starttime);
	while((s := <-logch) != nil)
		sys->fprint(logfd, "%.10bd %s\n", now(), s);
}

starttime: big;
logch: chan of string;
timefd: ref Sys->FD;
log(s: string)
{
	if(logch != nil)
		logch <-= s;
}

# time in milliseconds since scheduler was started
now(): big
{
	buf := array[24] of byte;
	n := sys->pread(timefd, buf, len buf, big 0);
	if(n <= 0)
		return big 0;
	return big string buf[0:n] / big 1000 - starttime;
}
