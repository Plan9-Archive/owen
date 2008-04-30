implement Splitgen, Taskgenerator, Simplegen;
include "sys.m";
	sys: Sys;
include "attributes.m";
include "taskgenerator.m";
include "tgsimple.m";
include "arg.m";

Splitgen: module {
};

Result: adt {
	n: int;
	gotc: chan of int;
	next: cyclic ref Result;
};

Aborted: array of byte;

resultlock: chan of int;
pendhd, pendtl: ref Result;
newtask: chan of (array of byte, chan of string);
result: chan of (int, int, chan of array of byte, chan of int);
admin2sched: chan of (array of byte, chan of string);
sched2admin: chan of array of byte;
startedreader := 0;
startedwriter := 0;
writefinished := 0;

init(jobid: string, state: string, argv: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgsimple := load TGsimple TGsimple->PATH;
	if(tgsimple == nil)
		return (nil, sys->sprint("cannot load %q: %r", TGsimple->PATH));
	gen := load Simplegen "$self";
	if(gen == nil)
		return (nil, sys->sprint("cannot load self as Simplegen: %r"));

	arg := load Arg Arg->PATH;
	arg->init(argv);
	USAGE: con "split [-kav] jobtype [arg...]";

	params := TGsimple->Defaultparams;
	while((opt := arg->opt()) != 0){
		case opt{
		'k' =>
			params.keepfailed = 1;
		'a' =>
			params.keepall = 0;
		'v' =>
			params.verbose = 1;
		* =>
			return (nil, USAGE);
		}
	}
	argv = arg->argv();
	if(len argv < 1)
		return (nil, USAGE);

	Aborted = array[0] of byte;
	resultlock = chan[1] of int;
	newtask = chan of (array of byte, chan of string);
	result = chan of (int, int, chan of array of byte, chan of int);
	admin2sched = chan of (array of byte, chan of string);
	sched2admin = chan of array of byte;

	return tgsimple->init(params, argv, jobid, state, gen);
}

simpleinit(nil, nil, nil: string): (int, string)
{
	sys = load Sys Sys->PATH;
	spawn tasksproc(admin2sched, newtask);
	spawn resultsproc(result, sched2admin);
	return (-1, nil);
}

state(): string
{
	return nil;
}

# get is called single-threaded only, hence we can send a sequence
# of packets on d without risk of overlap.
get(fd: ref Sys->FD): int
{
	acktask: chan of string;
	d: array of byte;
gettask:
	for(;;){
		(d, acktask) = <-newtask;
		if(d == nil){
			acktask <-= nil;
			return -1;
		}
		e := "";
		do{
			# XXX if a write fails, is it better to just skip the task,
			# or terminate the job?
			if(sys->write(fd, d, len d) == -1){
				e = "task write failed";
				log(sys->sprint("write task param data failed: %r"));
			}
			(d, nil) = <-newtask;
			if(d == Aborted){
				# if client has gone away, start again from the beginning
				sys->seek(fd, big 0, Sys->SEEKSTART);
				stat := Sys->nulldir;
				stat.length = big 0;
				if(sys->fwstat(fd, stat) == -1){
					log(sys->sprint("cannot truncate param file: %r"));
					# XXX we'll just have to hope for the best; could do fd2path & create, i suppose
					# XXX change devfs-posix and others so at the very least they give an
					# error message if trying to change the length and failing.
				}
				continue gettask;
			}
		}while(d != nil);
		if(e != nil){
			acktask <-= e;
			return -1;
		}
		break;
	}
	stat := Sys->nulldir;
	stat.name = "param";
	if(sys->fwstat(fd, stat) == -1){
		log(sys->sprint("cannot rename param file for task: %r"));
		acktask <-= "rename failed";
		return -1;
	}
	fd = nil;
	# XXX could wstat(nothing) to commit data to stable storage.
	# otherwise it's possible a crash could lose the data.
	acktask <-= nil;
	return 0;
}

# XXX think about what we actually want here... a shell command?
verify(nil: int, fd: ref Sys->FD): string
{
	(ok, stat) := sys->fstat(fd);
	if(ok != -1 && stat.length > big 0)
		return nil;
	return "nope";
}

# send a result to the client.
# don't return until we know they've got it.
put(n: int, fd: ref Sys->FD)
{
	gotc := chan of int;
	dc := chan of array of byte;
	(ok, stat) := sys->fstat(fd);
	if(ok == -1){
		log(sys->sprint("cannot stat result file %d: %r", n));
		return;
	}
	nb := int stat.length;
	result <-= (n, nb, dc, gotc);
	while(nb > 0){
		r := Sys->ATOMICIO;
		if(nb < r)
			r = nb;
		d := array[r] of byte;
		r = sys->read(fd, d, len d);
		if(r <= 0)
			break;
		dc <-= d[0:r];
		nb -= r;
	}
	# if we've got less than we should have from the results file,
	# fill the rest with zeros to keep client happy.
	if(nb > 0){
		log("truncated result file, task " + string n);
		d := array[Sys->ATOMICIO] of {* => byte 0};
		while(nb > 0){
			r := Sys->ATOMICIO;
			if(nb < r)
				r = int nb;
			dc <-= d[0:r];
			nb -= r;
		}
	}
	<-gotc;
}

complete()
{
	spawn stopresults();
}

stopresults()
{
	result <-= (-1, 0, nil, nil);
}

quit()
{
}

opendata(nil: string,
	mode: int,
	read: chan of Readreq,
	write: chan of Writereq,
	clunk: chan of int): string
{
	mode &= ~Sys->OTRUNC;
	case mode {
	Sys->OREAD =>
		if(startedreader)
			return "already opened";
		startedreader = 1;
		spawn datareadproc(read, clunk);
	Sys->OWRITE =>
		if(startedwriter)
			return "already opened";
		if(writefinished)
			return "no more writing allowed";
		startedwriter = 1;
		spawn datawriteproc(write, clunk);
	* =>
		return "invalid open mode";
	}
	return nil;
}

# gather tasks written to admin2sched, and send them to
# get requests when they arrive.
#
# a task is sent on newtask as a sequence of data packets
# terminated by nil; only the first of the sequence contains
# a reply channel - acktask - which should be responded to
# only once for the whole task.
# if the user goes away, (Aborted, nil) is sent on newtask
# to indicate that the task transmission has been interrupted.
# (no reply should be made in this case)
#
# assume that message headers aren't split across packets
# and there isn't more than one header per packet.
tasksproc(admin2sched: chan of (array of byte, chan of string),
		newtask: chan of (array of byte, chan of string))
{
	eof := 0;
	treply := chan of string;
gather:
	while(((d, reply) := <-admin2sched).t0 != nil){
		if(reply == nil || len d == 0)
			continue;			# aborted
		for(i := 0; i < len d; i++)
			if(d[i] == byte '\n')
				break;
		if(i == len d){
			reply <-= "invalid header";
			continue;
		}
		s := string d[0:i];
		d = d[i+1:];
		(ntoks, toks) := sys->tokenize(s, " ");
		if(ntoks == 0){
			reply <-= "invalid header";
			continue;
		}
		case hd toks {
		"data" =>
			if(eof)
				log("task received after eof");	# shouldn't happen, but be defensive.
			# syntax: data nbytes
			if(ntoks < 2){
				reply <-= "too few fields in msg header";
				continue;
			}
			if(eof){
				reply <-= "can't send tasks after eof";
				continue;
			}
			ndata := int hd tl toks;
			while(ndata > len d){
				reply <-= nil;
				newtask <-= (d, treply);
				ndata -= len d;
				(d, reply) = <-admin2sched;
				if(reply == nil){
					newtask <-= (Aborted, nil);
					continue gather;
				}
			}
			if(ndata > 0)
				newtask <-= (d[0:ndata], treply);
			newtask <-= (nil, treply);
			<-treply;
		"got" =>
			# syntax: got n
			if(ntoks < 2){
				reply <-= "too few fields in msg header";
				continue;
			}
			c := unregister(int hd tl toks);
			if(c == nil){
				reply <-= "unknown task";
				continue;
			}
			c <-= 1;
		"eof" =>
			newtask <-= (nil, treply);
			<-treply;
			eof = 1;
		* =>
			log(sys->sprint("unknown msg %q", s));
		}
		reply <-= nil;
	}
}

# send results to admin, waiting for acknowledgment
resultsproc(result: chan of (int, int, chan of array of byte, chan of int),
		sched2admin: chan of array of byte)
{
loop:
	for(;;) {
		(n, length, dc, gotc) := <-result;
		if(dc == nil)
			break loop;
		d := array of byte sys->sprint("data %d %d\n", length, n);
		length += len d;
		while(len d < length){
			sched2admin <-= d;
			length -= len d;
			d = <-dc;
		}
		register(n, gotc);
		sched2admin <-= d;
	}
	sched2admin <-= nil;
}

register(n: int, got: chan of int)
{
	r := ref Result(n, got, nil);
	resultlock <-= 1;
	if(pendhd == nil)
		pendhd = pendtl = r;
	else
		pendtl.next = r;
	<-resultlock;
}

unregister(n: int): chan of int
{
	resultlock <-= 1;
	prev: ref Result;
	for(r := pendhd; r != nil; r = r.next){
		if(r.n == n)
			break;
		prev = r;
	}
	if(r == nil){
		<-resultlock;
		return nil;
	}
	if(prev == nil)
		pendhd = r.next;
	else
		prev.next = r.next;
	<-resultlock;
	return r.gotc;
}

log(s: string)
{
	sys->print("splitgen: %s\n", s);
}

# stick packets together, but don't split packets.
agglomerate(in, realout: chan of array of byte)
{
	bufsize: con Sys->ATOMICIO;
	buf: array of byte;
	n := 0;
	out := dummyout := chan of array of byte;
loop:
	for(;;) alt {
	d := <-in =>
		if(d == nil)
			break loop;
		# if we can't buffer it, send the current buffer, and buffer the current data.
		if(len d >= bufsize - n){
			realout <-= buf[0:n];
			buf = d;
			n = len buf;
		# if there's stuff in the buffer, then add to it
		}else if(len buf > 0){
			if(len buf < bufsize){
				n = len buf;
				buf = (array[bufsize] of byte)[0:] = buf;
			}
			buf[n:] = d;
			n += len d;
		# no stuff in the buffer - just replace buffer with current data.
		}else{
			buf = d;
			n = len buf;
		}
		out = realout;
	out <-= buf[0:n] =>
		buf = nil;
		out = dummyout;
	}
	if(n > 0)
		realout <-= buf[0:n];
	realout <-= nil;
}

# get read requests, fill from sched2admin
datareadproc(read: chan of Readreq, clunk: chan of int)
{
	d: array of byte;
	for(;;)alt{
	(n, reply, flushc) := <-read =>
		if(len d == 0)
			if((d = <-sched2admin) == nil)
				d = array[0] of byte;		# make sure we don't act like we've been flushed.
		alt{
		flushc <-= 1 =>
			r := d;
			if(len d > n){
				r = d[0:n];
				d = d[n:];
			}else
				d = nil;
			reply <-= r;
		* =>
			reply <-= nil;			# flushed
		}
	<-clunk =>
		startedreader = 0;
		exit;
	}
}

datawriteproc(write: chan of Writereq, clunk: chan of int)
{
	sreply := chan of string;
	for(;;)alt{
	(d, reply, flushc) := <-write =>
		if(len d == 0){
			writefinished = 1;
			alt{
			flushc <-= 1 =>
				reply <-= nil;
			* =>
				reply <-= "flushed";
			}
			continue;
		}
		# send the data or get flushed.
		alt{
		admin2sched <-= (d, sreply) =>
			;
			# we can't commit to the write because it might block for
			# ages, potentially blocking out the entire scheduler.
			# well, the worst thing that could happen is that a client
			# thinks it hasn't written some data when in fact it has.
			# if we don't wish to support restartable clients
		<-flushc =>
			reply <-= "flushed";
			continue;
		}

		alt{
		e := <-sreply =>
			alt{
			flushc <-= 1 =>
				reply <-= e;		# XXX vulnerable if someone returns "flushed"
			* =>
				log("unfortunate flush; reply lost");
				reply <-= "flushed";
			}
		<-flushc =>
			log("unfortunate flush; reply lost");
			reply <-= "flushed";
			<-sreply;
		}
	<-clunk =>
		startedwriter = 0;
		if(writefinished)
			admin2sched <-= (nil, nil);
		else
			admin2sched <-= (array[0] of byte, nil);
		exit;
	}
}

# # get write requests and send them to admin2sched.
# #
# # note we've got a potential problem with flush, as we can't commit to
# # the write before sending the value on admin2sched, as that write might
# # block indefinitely, and we could end up blocking out the whole
# # scheduler; but if we've done the write and then commit then we can't
# # unwrite the data.  in practise this shouldn't be a problem as client
# # should only flush if it's stopped, and shouldn't write again.
# datawriteproc(write: chan of Writereq, clunk: chan of int)
# {
# 	done := 0;
# 	for(;;)alt{
# 	(d, reply, flushc) := <-write =>
# 		if(len d == 0)
# 			done = 1;
# 		alt{
# 		admin2sched <-= d =>
# 			alt{
# 			flushc <-= 1 =>
# 				reply <-= nil;
# 			* =>
# 				log("unfortunate flush");
# 				reply <-= "flushed";
# 			}
# 		<-flushc =>
# 			reply <-= "flushed";
# 		}
# 	<-clunk =>
# 		startedwriter = 0;
# 		if(done)
# 			admin2sched <-= nil;
# 		exit;
# 	}
# }
