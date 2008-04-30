implement File2rec;

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

File2rec: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;

	iob := bufio->fopen(sys->fildes(1), Sys->OWRITE);
	for(argv = tl argv; argv != nil; argv = tl argv){
		fd := sys->open(hd argv, Sys->OREAD);
		if(fd == nil){
			sys->fprint(sys->fildes(2), "file2rec: cannot open %q: %r\n", hd argv);
			continue;
		}
		(ok, stat) := sys->fstat(fd);
		if(ok == -1){
			sys->fprint(sys->fildes(2), "file2rec: cannot stat %q: %r\n", hd argv);
			continue;
		}
		l := int stat.length;
		iob.puts(sys->sprint("data %d %q\n", l, hd argv));
		buf := array[Sys->ATOMICIO] of byte;
		tot := 0;
		while((n := sys->read(fd, buf, len buf)) > 0){
			tot += n;
			if(tot > l){
				n -= (tot - n);
				sys->fprint(sys->fildes(2), "file2rec: %q is longer than expected\n", hd argv);
				tot = l;
			}
			iob.write(buf, n);
		}
		if(tot < l){
			sys->fprint(sys->fildes(2), "file2rec: %q is shorter than expected, quitting\n", hd argv);
			exit;
		}
	}
	iob.close();
}
