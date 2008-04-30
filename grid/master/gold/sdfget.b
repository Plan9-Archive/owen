implement Sdfget;

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Sdfget: module {
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

	nrecs := 1;
	indexpath := "";

	arg->init(argv);
	arg->setusage("sdfget [-n nrecs] [-i index] path recno");
	while((opt := arg->opt()) != 0){
		case opt {
		'n' =>
			nrecs = int arg->earg();
			if (nrecs <= 0)
				arg->usage();
		'i' =>
			indexpath = arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if(len argv != 2)
		arg->usage();
	arg = nil;

	path := hd argv;
	recno := int hd tl argv;

	in := bufio->open(path, Sys->OREAD);
	if (in == nil)
		fail(sys->sprint("cannot open %s: %r", path));
	out := bufio->fopen(stdout(), Sys->OWRITE);
	if (out == nil)
		fail(sys->sprint("cannot fopen stdout: %r"));

	if(indexpath != nil){
		(index, e) := openindex(indexpath, path);
		if(index == nil){
			sys->fprint(stderr(), "sdfget: ignoring index %s: %s\n", indexpath, e);
			indexpath = nil;
		}else{
			index.seek(big (recno * 4), Sys->SEEKRELA);
			ibuf := array[4] of byte;
			if(index.read(ibuf, len ibuf) < 4)
				return;			# past end of file
			in.seek(big g32(ibuf), Sys->SEEKSTART);
		}
	}
	if(indexpath == nil)
		for (i := 0; i < recno; i++)
			if (!consume(in))
				return;

	for (i = 0; i < nrecs; i++)
		if (!copy(in, out))
			break;
	out.flush();
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
	sys->fprint(stderr(), "sdfget: cannot load module %s: %r\n", path);
	raise "fail:init";
}

fail(msg: string)
{
	sys->fprint(stderr(), "sdfget: %s: %r\n", msg);
	raise "fail:runtime";
}

stdout(): ref Sys->FD
{
	return sys->fildes(1);
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

basename(s: string): string
{
	for ((nil, ls) := sys->tokenize(s, "/"); ls != nil; ls = tl ls)
		s = hd ls;
	return s;
}

SEP1: con "$$$$\n";
SEP2: con "$$$$\r\n";

consume(iob: ref Iobuf): int
{
	reclen := 0;
	for (;;) {
		line := iob.gets('\n');
		if (line == nil)
			break;
		if (line[0] == '$' && (line == SEP1 || line == SEP2) && reclen)
			break;
		reclen++;
	}
	return reclen != 0;
}

copy(in, out: ref Iobuf): int
{
	reclen := 0;
	end := 0;
	for (;end == 0;) {
		line := in.gets('\n');
		if (line == nil)
			break;
		if (line[0] == '$' && (line == SEP1 || line == SEP2)) {
			if (!reclen)
				continue;
			end = 1;
		}
		out.puts(line);
		reclen++;
	}
	return reclen != 0;
}

g32(f: array of byte): int
{
	return (((((int f[3] << 8) | int f[2]) << 8) | int f[1]) << 8) | int f[0];
}
