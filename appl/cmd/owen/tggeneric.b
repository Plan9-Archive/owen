implement TGgeneric;
include "sys.m";
	sys: Sys;
include "bufio.m";
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "keyring.m";
	keyring: Keyring;
include "taskgenerator.m";
	Taskgenreq, Clientspec, Readreq, Writereq, Finishreq,
	Nomore, Error, Started: import Taskgenerator;
include "tggeneric.m";

gen: Simplegen;

Verbose: con 1;
Maxread: con 128*1024;		# prevent malicious client from using all our buffer space.

IO: adt {
	read:		chan of Taskgenerator->Readreq;
	write:	chan of Taskgenerator->Writereq;
	finish:	chan of Taskgenerator->Finishreq;

	getreadreq: fn(io: self ref IO): (int, chan of array of byte);
	getwritereq: fn(io: self ref IO): (array of byte, chan of string);
};

init(): string
{
	sys = load Sys Sys->PATH;
	sexprs = load Sexprs Sexprs->PATH;
	if(sexprs == nil)
		return sys->sprint("cannot load %s: %r", Sexprs->PATH);
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return sys->sprint("cannot load %s: %r", Keyring->PATH);
	sexprs->init();
	attributes = load Attributes Attributes->PATH;
	if(attributes == nil)
		return sys->sprint("cannot load %s: %r", Attributes->PATH);
	return nil;
}

start(mod: Simplegen): chan of ref Taskgenreq
{
	gen = mod;
	c := chan of ref Taskgenreq;
	spawn taskgenproc(gen, c);
	return c;
}

checkspec(spec: ref Clientspec, tasktype: string, space: big): string
{
	if((v := spec.attrs.get("cachesize")) == nil)
		return "old client";
	if(big v < space)
		return "insufficient space";
	
	a := spec.attrs.a;
	for(i := 0; i < len a; i++)
		if(prefix(a[i].t0, "jobtype") && a[i].t1 == tasktype)
			return nil;
	return "task not supported";
}	

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

taskgenproc(gen: Simplegen, reqch: chan of ref Taskgenreq)
{
	while((req := <-reqch) != nil){
		pick r := req {
		Taskcount =>
			r.reply <-= gen->taskcount();
		Opendata =>
			r.reply <-= gen->opendata(r.user, r.mode, r.read, r.write, r.clunk);
		Start =>
			r.reply <-= starttask(r.tgid, r.failed, r.spec, ref IO(r.read, r.write, r.finish));
		Reconnect =>
			r.reply <-= reconnect(r.tgid, ref IO(r.read, r.write, r.finish));
		State =>
			r.reply <-= gen->state();
		Complete =>
			gen->complete();
		}
	}
	gen->quit();
}

starttask(id: string, tries: int, spec: ref Clientspec, io: ref IO): (int, string)
{
	(status, t, err) := gen->start(id, tries, spec);
	if(status == Started){
		spawn taskproc(io, t);
		return (Started, t.id);
	}
	return (status, err);
}

# reconnect protocol
#	client writes results.
reconnect(id: string, io: ref IO): (int, string)
{
	(t, err) := gen->reconnect(id);
	if(t == nil)
		return (Nomore, err);
	spawn getresults(io, t);
	return (Started, nil);
}

# protocol:
# client reads job args.
# client reads any data it requires but hasn't got.
# loop
#	client write file request (or nothing)
#	client read file
# client writes results
taskproc(io: ref IO, t: ref Task)
{
	{
		sendtaskspec(io, t);
		if(hasfiles(t))
			while(senddata(io, t))
				;
		getresults(io, t);
	} exception {
	"task close" =>
		gen->finalise(t, 0);
	}
}

sendtaskspec(io: ref IO, t: ref Task)
{
	# client reads task specification:
	# (task ("args" taskarg...) ("input" ("file" name hash size kind) ...))
	input: list of ref Sexp;
	for(dl := t.params; dl != nil; dl = tl dl){
		pick d := hd dl {
		File =>
			input = sl(ss("file") :: ss(d.name) :: sb(d.hash) :: ss(string d.size) :: ss(d.kind) :: nil) :: input;
		Value =>
			input = sl(ss("value") :: ss(d.name) :: sexplist(d.v)) :: input;
		}
	}
	args := sexplist(t.taskargs);
		
	data := sl(ss("task") :: sl(ss("args") :: args) ::  sl(ss("input") :: input) :: sl(ss("output") :: ss(t.outkind) :: nil) :: nil).pack();
	input = args = nil;
	# we rely on the client not reading beyond the end of the s-expression,
	# something that sexprs.b guarantees.
	while(len data > 0){
		(n, rreply) := io.getreadreq();
		if(n > len data)
			n = len data;
		rreply <-= data[0:n];
		data = data[n:];
	}
}

sexplist(l: list of string): list of ref Sexp.String
{
	el: list of ref Sexp.String;
	for(; l != nil; l = tl l)
		el = ss(hd l) :: el;
	return rev(el);
}

hasfiles(t: ref Task): int
{
	for(pl := t.params; pl != nil; pl = tl pl)
		if(tagof(hd pl) == tagof(Param.File))
			break;
	return pl != nil;
}

# give the client a file if it requests one; return 0 if it doesn't want any more.
senddata(io: ref IO, t: ref Task): int
{
	# client writes file hash request
	(data, wreply) := io.getwritereq();
	if(len data == 3 && string data == "end"){
		wreply <-= nil;
		return 0;
	}
	d: ref Param.File;
loop:
	for(dl := t.params; dl != nil; dl = tl dl){
		pick f := hd dl {
		File =>
			if(eqbytes(f.hash, data)){
				d = f;
				break loop;
			}
		}
	}
	if(dl == nil){
		wreply <-= "file for given hash not found";
		return 1;
	}
	wreply <-= nil;
	off := d.soff;
	for(;;){
		(n, rreply) := io.getreadreq();
		if(off + big n > d.eoff)
			n = int (d.eoff - off);
		if(n > Maxread)
			n = Maxread;
		data = array[n] of byte;
		nr := sys->pread(d.fd, data, n, off);
		if(nr == -1){
			log(sys->sprint("taskparam readerror %q %q", sys->fd2path(d.fd), sys->sprint("%r")));
			nr = 0;
		}
		if(nr < n)
			data = data[0:nr];
		rreply <-= data;
		if(len data == 0)
			break;
		off += big len data;
		data = nil;
	}
	return 1;
}

getresults(io: ref IO, t: ref Task)
{
	errfd: ref Sys->FD;
	done := 0;
	error: string;
	# XXX should we get a hash of the data
	# before/after it's sent, to confirm the contents?
	for(;;)alt{
	(nil, reply, flushc) := <-io.read =>
		alt{
		flushc <-= 1 =>
			reply <-= array[0] of byte;
		* =>
			reply <-= nil;
		}
	(d, reply, flushc) := <-io.write =>
		alt{
		flushc <-= 1 =>
			if(done){
				if(error != nil || t.errfile == nil)
					reply <-= "no more data allowed";
				else{
					# create error file lazily so as not to inconvenience
					# fast-completing successful tasks.
					if(errfd == nil){
						if((errfd = sys->create(t.errfile, Sys->OWRITE, 8r666)) == nil){
							log(sys->sprint("taskresult-err createrror %q %#q %q",
								t.errfile, t.id, sys->sprint("%r")));
							t.errfile = nil;
						}
					}
					if(errfd != nil && sys->write(errfd, d, len d) != len d){
						e := sys->sprint("%r");
						log(sys->sprint("taskresult-err writeerror %q %#q %q",
							t.errfile, t.id, e));
						errfd = nil;
						t.errfile = nil;
					}
					reply <-= nil;
				}
			}else if(len d == 0){
				done = 1;
				reply <-= nil;
			}else{
				if(sys->write(t.out, d, len d) != len d){
					e := sys->sprint("%r");
					log(sys->sprint("taskresult writeerror %q %#q %q", sys->fd2path(t.out), t.id, e));
					done = 1;
					error = "result write error: "+e;
					reply <-= e;
				}else
					reply <-= nil;
			}
		* =>
			reply <-= "flushed";
		}
	(first, duration, reply) := <-io.finish =>
		if(!done)
			error = "disconnected";
		if(error == nil)
			error = gen->verify(t, duration);
		if(error != nil)
			log(sys->sprint("task verify-error %#q %#q", t.id, error));
		reply <-= error;
		gen->finalise(t, error == nil && first);
		return;
	}
}

IO.getreadreq(io: self ref IO): (int, chan of array of byte)
{
	for(;;)alt{
	(n, reply, flushc) := <-io.read =>
		alt{
		flushc <-= 1 =>
			return (n, reply);
		* =>
			reply <-= nil;
		}
	(nil, reply, flushc) := <-io.write =>
		alt{
		flushc <-= 1 =>
			reply <-= "write not allowed";
		* =>
			reply <-= "flushed";
		}
	(nil, nil, reply) := <-io.finish =>
		reply <-= "task ended too early (expected read)";
		raise "task close";
	}
}

IO.getwritereq(io: self ref IO): (array of byte, chan of string)
{
	for(;;)alt{
	(nil, reply, flushc) := <-io.read =>
		alt{
		flushc <-= 1 =>
			reply <-= array[0] of byte;		# XXX would be nice to be able to return error here.
		* =>
			reply <-= nil;
		}
	(d, reply, flushc) := <-io.write =>
		alt{
		flushc <-= 1 =>
			return (d, reply);
		* =>
			reply <-= "flushed";
		}
	(nil, nil, reply) := <-io.finish =>
		reply <-= "task ended too early (expected write)";
		raise "task close";
	}
}

eqbytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

ss(s: string): ref Sexp.String
{
	return ref Sexp.String(s, nil);
}

sl(l: list of ref Sexp): ref Sexp.List
{
	return ref Sexp.List(l);
}

sb(b: array of byte): ref Sexp.Binary
{
	return ref Sexp.Binary(b, nil);
}

hash(fd: ref Sys->FD, soff, eoff: big): array of byte
{
	sys->seek(fd, soff, Sys->SEEKSTART);
	off := soff;
	buf := array[Sys->ATOMICIO] of byte;
	state: ref Keyring->DigestState;
	while(off < eoff){
		if(off + big len buf > eoff)
			buf = buf[0:int (eoff - off)];
		if((n := sys->pread(fd, buf, len buf, off)) <= 0)
			break;
		state = keyring->md5(buf, n, nil, state);
		off += big n;
	}
	buf = nil;
	keyring->md5(buf, 0, hash := array[keyring->MD5dlen] of byte, state);
	return hash;
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

debug(msg: string)
{
	if (Verbose)
		sys->print("%s\n", msg);
}

log(msg: string)
{
	sys->print("%s\n", msg);
}
