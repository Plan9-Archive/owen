implement Filesplitgen, Taskgenerator, Simplegen;
include "sys.m";
	sys: Sys;
include "attributes.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "taskgenerator.m";
include "tgsimple.m";
include "arg.m";

Filesplitgen: module {
};

resultfile, paramfile: string;
resultf, paramf: ref Iobuf;

nstarted := 0;
outfileoffset := big 0;
lineinput := 0;
nooutrecords := 0;

init(root, work: string, state: string, kick: chan of int, argv: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgsimple := load TGsimple TGsimple->PATH;
	if(tgsimple == nil)
		return (nil, sys->sprint("cannot load %q: %r", TGsimple->PATH));
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return (nil, sys->sprint("cannot load %q: %r", Bufio->PATH));
	gen := load Simplegen "$self";
	if(gen == nil)
		return (nil, sys->sprint("cannot load self as Simplegen: %r"));

	arg := load Arg Arg->PATH;
	arg->init(argv);
	USAGE: con "filesplit [-kav] [-ln] [-o resultfile] file jobtype [arg...]";
 
	params := TGsimple->Defaultparams;
	while((opt := arg->opt()) != 0){
		case opt{
		'k' =>
			params.keepfailed = 1;
		'a' =>
			params.keepall = 1;
		'n' =>
			nooutrecords = 1;
		'l' =>
			lineinput = 1;
		'v' =>
			params.verbose = 1;
		'o' =>
			if((resultfile = arg->arg()) == nil)
				return (nil, USAGE);
		* =>
			return (nil, USAGE);
		}
	}
	argv = arg->argv();
	if(len argv < 2)
		return (nil, USAGE);
	(paramfile, argv) = (hd argv, tl argv);
	if(resultfile == nil)
		resultfile = paramfile+".result";
	return tgsimple->init(params, argv, root, work, state, kick, gen);
}

simpleinit(nil, nil, state: string): (int, string)
{
	# XXX should be able to read through paramfile and count
	# the number of records.
	paramf = bufio->open(paramfile, Sys->OREAD);
	if(paramf == nil)
		return (-1, sys->sprint("cannot open %q: %r", paramfile));
	if(state == nil){
		resultf = bufio->create(resultfile, Sys->OWRITE, 8r666);
		if(resultf == nil)
			return (-1, sys->sprint("cannot create result file %q: %r", resultfile));
	}else{
		(nil, toks) := sys->tokenize(state, " ");
		nstarted = int hd toks;
		outfileoffset = big hd tl toks;
		resultf = bufio->open(resultfile, Sys->OWRITE);
		if(resultf == nil)
			return (-1, sys->sprint("cannot reopen %q: %r", resultfile));
		resultf.seek(outfileoffset, Sys->SEEKSTART);
		for(i := 0; i < nstarted; i++)
			readrec(paramf, nil);
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

put(n: int, fd: ref Sys->FD)
{
sys->print("putting record %d\n", n);	
	putrec(fd, resultf, n);
}

complete()
{
	resultf.flush();
}

quit()
{
}

opendata(nil: string,
	nil: int,
	nil: chan of Readreq,
	nil: chan of Writereq,
	nil: chan of int): string
{
	return "permission denied";
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
	sys->print("filesplit: %s\n", s);
}

# XXX implement this, if we think it's worth it.
writezeros(nil: int, nil: ref Sys->FD)
{
	x: chan of int;
	# abort
	<-x;
}
