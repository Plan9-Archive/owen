implement Workflowgen, Taskgenerator, Simplegen;
include "sys.m";
	sys: Sys;
include "attributes.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "alphabet/endpoints.m";
	endpoints: Endpoints;
	Endpoint: import endpoints;
include "taskgenerator.m";
include "tgsimple.m";
include "arg.m";

Workflowgen: module {
};

paramep: Endpoint;
resultep: Endpoint;
paramf, resultf: ref Iobuf;
completed := 0;

nstarted := 0;
outfileoffset := big 0;
lineinput := 0;
nooutrecords := 0;

init(root, work, state: string, kick: chan of int, argv: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgsimple := load TGsimple TGsimple->PATH;
	if(tgsimple == nil)
		return (nil, sys->sprint("cannot load %q: %r", TGsimple->PATH));
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return (nil, sys->sprint("cannot load %q: %r", Bufio->PATH));
	endpoints = load Endpoints Endpoints->PATH;
	if(endpoints == nil)
		return (nil, sys->sprint("cannot load %s: %r", Endpoints->PATH));
	endpoints->init();
	gen := load Simplegen "$self";
	if(gen == nil)
		return (nil, sys->sprint("cannot load self as Simplegen: %r"));

	arg := load Arg Arg->PATH;
	arg->init(argv);
	USAGE: con "workflow [-kavln] [-b nbuf] endpoint jobtype [arg...]"; 

	params := TGsimple->Defaultparams;
	while((opt := arg->opt()) != 0){
		case opt{
		'k' =>
			params.keepfailed = 1;
		'a' =>
			params.keepall = 0;
		'n' =>
			nooutrecords = 1;
		'l' =>
			lineinput = 1;
		'v' =>
			params.verbose = 1;
		'b' =>
			if((p := arg->arg()) == nil || int p < 0)
				return (nil, USAGE);
			params.pendtasks = int p;
		* =>
			return (nil, USAGE);
		}
	}
	argv = arg->argv();
	if(len argv < 2)
		return (nil, USAGE);
	(paramep, argv) = (Endpoint.mk(hd argv), tl argv);
	if(paramep.addr == nil)
		return (nil, sys->sprint("invalid endpoint: %s", paramep.about));
	return tgsimple->init(params, argv, root, work, state, kick, gen);
}

simpleinit(nil, nil, state: string): (int, string)
{
	if(state != nil)
		return (-1, "XXX cannot restart yet");
	(fd, err) := endpoints->open(nil, paramep);	# XXX would be nice if other taskgens could share...
	if(fd == nil)
		return (-1, sys->sprint("cannot open endpoint %s [%q, %q]: %s", paramep.addr, paramep.id, paramep.text(), err));
	paramf = bufio->fopen(fd, Sys->OREAD);

	rfd: ref Sys->FD;
	(rfd, resultep) = endpoints->create("local");
	if(rfd == nil)
		return (-1, sys->sprint("cannot create endpoints: %s\n", resultep.about));
	resultf = bufio->fopen(rfd, Sys->OWRITE);

	if(state != nil){
		# XXX actually we don't want to create the endpoints if we're
		# re-starting - we just want to reconnect to the old result
		# endpoints
		return (-1, "XXX can't restart yet");
	}
	return (-1, nil);
}

state(): string
{
	return string nstarted+" "+string outfileoffset;
}

# get is called single-threaded only, hence we can send a sequence
# of packets on d without risk of overlap.
get(fd: ref Sys->FD): int
{
	o := readrec(paramf, fd);
	if(o == -1)
		return -1;
	stat := Sys->nulldir;
	stat.name = "param";
	if(sys->fwstat(fd, stat) == -1){
		log(sys->sprint("cannot rename param file for task: %r"));
		return -1;
	}
	nstarted++;
	return 0;
}

# XXX think about what we actually want here... a shell command?
verify(nil: int, fd: ref Sys->FD): string
{
	(ok, stat) := sys->fstat(fd);
	if(ok != -1 && stat.length > big 0)
		return nil;
	return "zero length result";
}

# send a result to the client.
# don't return until we know they've got it.
put(n: int, fd: ref Sys->FD)
{
	putrec(fd, resultf, n);
}

sendeof()
{
	resultf.flush();
	{
		sys->fprint(resultf.fd, "");
	}exception{
	"write on closed pipe" =>
		;
	}
}

complete()
{
	sendeof();
	completed  =1;
}

quit()
{
	if(!completed)
		sendeof();
}

opendata(nil: string,
	mode: int,
	read: chan of Readreq,
	nil: chan of Writereq,
	clunk: chan of int): string
{
	if(mode != Sys->OREAD)
		return "permission denied";
	spawn epreadproc(read, clunk);
	return nil;
}

epreadproc(read: chan of Readreq, clunk: chan of int)
{
	readrendez(read, clunk, array of byte resultep.text());
	readrendez(read, clunk, array[0] of byte);
}

readrendez(read: chan of Readreq, clunk: chan of int, data: array of byte)
{
	for(;;)alt{
	(n, reply, flushc) := <-read =>
		alt{
		flushc <-= 1 =>
			reply <-= data;
			if(n >= len data)
				return;
			data = data[n:];
		* =>
			reply <-= nil;
		}
	<-clunk =>
		exit;
	}
}

readrec(f: ref Iobuf, fd: ref Sys->FD): int
{
	h := f.gets('\n');
	if(h == nil)
		return -1;
	if(lineinput){
		sys->fprint(fd, "%s", h);
		return 0;
	}
	if(len h < len "data " || h[0:len "data "] != "data "){
		log(sys->sprint("invalid data record header %#q", h));
		return -1;
	}
	nb := int h[len "data ":];
	buf := array[Sys->ATOMICIO] of byte;
	nr := 0;
	while(nr < nb){
		n := nb - nr;
		if(n > len buf)
			n = len buf;
		n = f.read(buf, n);
		if(n <= 0)
			return -1;
		if(sys->write(fd, buf, n) != n){
			log(sys->sprint("error writing record: %r"));
			return -1;
		}
		nr += n;
	}
	return 0;
}

putrec(fd: ref Sys->FD, f: ref Iobuf, rec: int): int
{
	buf := array[Sys->ATOMICIO] of byte;
	if(nooutrecords){
		nb := 0;
		while((n := sys->read(fd, buf, len buf)) > 0){
			if(f.write(buf, n) != n){
				log(sys->sprint("write record %d failed: %r", rec));
				return -1;
			}
			nb += n;
		}
		f.flush();
		outfileoffset += big nb;
		return 0;
	}
	
	(ok, stat) := sys->fstat(fd);
	if(ok == -1){
		log(sys->sprint("cannot stat result file: %r"));
		return -1;
	}
	nb := int stat.length;
	f.puts("data "+string nb+" "+string rec+"\n");
	nr := 0;
	while(nr < nb){
		n := nb - nr;
		if(n > len buf)
			n = len buf;
		n = sys->read(fd, buf, n);
		if(n <= 0){
			log(sys->sprint("truncated record %d (length %d, expected %d)", rec, nr, nb));
			# produce garbage at the end to satisfy record length invariant
			writezeros(nb - nr, fd);
			return -1;
		}
		if(f.write(buf, n) != n){
			log(sys->sprint("write record %d failed: %r", rec));
			return -1;
		}
		nr += n;
	}
	f.flush();				# XXX should really disk sync at this point
	outfileoffset += big nb;
	return 0;
}

log(s: string)
{
	sys->print("workflow: %s\n", s);
}

# XXX implement this, if we think it's worth it.
writezeros(nil: int, nil: ref Sys->FD)
{
	x: chan of int;
	# abort
	<-x;
}
