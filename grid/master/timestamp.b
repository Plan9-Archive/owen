implement Test;
include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Test: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

timefd: ref Sys->FD;
starttime: big;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;

	timefd = sys->open("/dev/time", Sys->OREAD);
	starttime = now();

	sys->print("%.10bd start %bd\n", now(), starttime);

	iob := bufio->fopen(sys->fildes(0), Sys->OREAD);
	while((s := iob.gets('\n')) != nil)
		sys->print("%.10bd %s", now(), s);
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
