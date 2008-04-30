implement Indexes;
include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "indexes.m";

Wordlen: con 4;

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->sopen("");
}

Index.open(indexpath, path: string): (ref Index, string)
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
	start := indexf.offset();
	indexf.seek(big 0, Sys->SEEKEND);
	return (ref Index(indexf, int start, int ((indexf.offset() - start) / big Wordlen), stat.length), nil);
}

Index.create[T](indexpath, file: string, t: T): (ref Index, string)
	for{
	T =>
		skiprec: fn(t: self T, iob: ref Iobuf): int;
	}
{
	in := bufio->open(file, Sys->OREAD);
	if(in == nil)
		return (nil, sys->sprint("cannot open %q: %r", file));
	index := bufio->create(indexpath, Sys->ORDWR, 8r666);
	if(index == nil)
		return (nil, sys->sprint("cannot create index %q: %r", indexpath));
	(ok, stat) := sys->stat(file);
	if(ok == -1)
		return (nil, sys->sprint("cannot stat %q: %r", file));
	# XXX could write larger index entries if 32 bits is not enough.
	if(stat.length > big 16r7fffffff)
		return (nil, sys->sprint("%q is too huge", file));
	h := sys->sprint("sdfindex %bd\n", stat.length);
	index.puts(h);

	ibuf := array[Wordlen] of byte;
	offset := 0;
	for(total := 0; t.skiprec(in) != 0; total++){
		p32(ibuf, offset);
		index.write(ibuf, len ibuf);
		offset = int in.offset();
	}
	index.flush();
	return (ref Index(index, len h, total, stat.length), nil);		# assume no utf in header.
}

Index.offsetof(i: self ref Index, recno: int): big
{
	if(recno >= i.nrecs)
		return i.filesize;

	i.index.seek(big (recno * 4) + big i.start, Sys->SEEKSTART);
	ibuf := array[4] of byte;
	if(i.index.read(ibuf, len ibuf) < 4)
		return i.filesize;			# past end of file (shouldn't happen)
	return big g32(ibuf);
}

p32(a: array of byte, v: int)
{
	a[0] = byte v;
	a[1] = byte (v>>8);
	a[2] = byte (v>>16);
	a[3] = byte (v>>24);
}

g32(f: array of byte): int
{
	return (((((int f[3] << 8) | int f[2]) << 8) | int f[1]) << 8) | int f[0];
}
