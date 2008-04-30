implement Sdfcount;

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Sdfcount: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if (bufio == nil)
		badmodule(Bufio->PATH);
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);

	indexpath := "";
	createindex := 0;

	arg->init(argv);
	arg->setusage("sdfcount [-c] [-i index] path");
	while((opt := arg->opt()) != 0){
		case opt {
		'c' =>
			createindex = 1;
		'i' =>
			indexpath = arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(len argv != 1 || (createindex && indexpath == nil))
		arg->usage();
	arg = nil;

	path := hd argv;

	in := bufio->open(path, Sys->OREAD);
	if (in == nil)
		fail("open failed", sys->sprint("cannot open %s: %r", path));

	if(createindex){
		sys->print("%d\n", writeindex(indexpath, path, in));
		exit;
	}
	indexf: ref Iobuf;
	if(indexpath != nil){
		e: string;
		(indexf, e) = openindex(indexpath, path);
		if(indexf != nil){
			start := int indexf.offset();
			indexf.seek(big 0, Sys->SEEKEND);
			sys->print("%d\n", (int indexf.offset() - start) / 4);
			exit;
		}
		sys->fprint(stderr(), "sdfcount: ignoring index %s: %s\n", indexpath, e);
	}
	for(total := 0; readrec(in) != 0; total++)
		;
	sys->print("%d\n", total);
}

writeindex(indexpath, path: string, in: ref Iobuf): int
{
	index := bufio->create(indexpath, Sys->OWRITE, 8r666);
	if(index == nil)
		fail("create failed", sys->sprint("cannot create %q: %r", indexpath));
	(ok, stat) := sys->stat(path);
	if(ok == -1)
		fail("stat failed", sys->sprint("cannot stat %s: %r", path));
	# XXX could write larger index entries if 32 bits is not enough.
	if(stat.length > big 16r7fffffff)
		fail("too huge", sys->sprint("%s is too huge", path));
	index.puts(sys->sprint("sdfindex %d\n", int stat.length));

	ibuf := array[4] of byte;
	offset := 0;
	for(total := 0; readrec(in) != 0; total++){
		p32(ibuf, offset);
		index.write(ibuf, len ibuf);
		offset = int in.offset();
	}
	index.close();
	return total;
}

openindex(indexpath, path: string): (ref Iobuf, string)
{
	indexf := bufio->open(indexpath, Sys->OREAD);
	if(indexf == nil)
		return (nil, sys->sprint("cannot open: %r"));
	(n, toks) := sys->tokenize(indexf.gets('\n'), " ");
	if(n != 2 || hd toks != "sdfindex")
		return (nil, "bad header");
	(ok, stat) := sys->stat(path);
	if(ok == -1 || stat.length != big hd tl toks)
		return (nil, "length mismatch");
	return (indexf, nil);
}

badmodule(path: string)
{
	sys->fprint(stderr(), "sdfcount: cannot load module %s: %r\n", path);
	raise "fail:init";
}

fail(f, msg: string)
{
	sys->fprint(stderr(), "sdfcount: %s: %r\n", msg);
	raise "fail:" + f;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

readrec(iob: ref Iobuf): int
{
	SEP1: con "$$$$\n";
	SEP2: con "$$$$\r\n";

	reclen := 0;
	for (;;) {
		line := iob.gets('\n');
		if (line == nil)
			break;
		if (line[0] == '$'  && (line == SEP1 || line == SEP2) && reclen)
			break;
		reclen++;
	}
	return reclen != 0;
}

p32(a: array of byte, v: int)
{
	a[0] = byte v;
	a[1] = byte (v>>8);
	a[2] = byte (v>>16);
	a[3] = byte (v>>24);
}
