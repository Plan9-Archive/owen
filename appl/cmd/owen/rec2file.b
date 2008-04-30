implement Rec2file;

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "string.m";
	str: String;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Rec2file: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

nflag := 0;
dir := ".";

nrec := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("rec2file [-n] [file...]");
	while((opt := arg->opt()) != 0){
		case opt {
		'n' =>
			nflag = 1;
		'd' =>
			dir = arg->earg();
		* =>
			arg->usage();
		}
	}

	argv = arg->argv();
	if(argv == nil)
		getrecs(bufio->fopen(sys->fildes(0), Sys->OREAD));
	else{
		for(; argv != nil; argv = tl argv){
			iob := bufio->open(hd argv, Sys->OREAD);
			if(iob == nil)
				log(sys->sprint("cannot open %q: %r\n", hd argv));
			else
				getrecs(iob);
		}
	}
}	

getrecs(f: ref Iobuf)
{
	while(getrec(f) != -1)
		;
}

getrec(f: ref Iobuf): int
{
	h := f.gets('\n');
	if(h == nil)
		return -1;
	toks := str->unquoted(h);
	if(toks == nil || hd toks != "data" || tl toks == nil){
		log(sys->sprint("invalid data record header %#q", h));
		return -1;
	}
	toks = tl toks;
	nb := int hd toks;
	name := string nrec++;
	if(!nflag && tl toks != nil && okname(hd tl toks))
		name = hd tl toks;
	fd := sys->create(dir+"/"+name, Sys->OWRITE, 8r666);
	if(fd == nil){
		log(sys->sprint("cannot create %q: %r\n", name));
		return -1;
	}

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

log(e: string)
{
	sys->fprint(sys->fildes(2), "rec2file: %s\n", e);
}

okname(s: string): int
{
	for(i := 0; i < len s; i++){
		case s[i] {
		0 to 31 =>
			return 0;
		'/' =>
			return 0;
		16r7f =>
			return 0;
		}
	}
	return s != "." && s != "..";
}
