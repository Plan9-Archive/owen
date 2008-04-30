implement Count;

include "sys.m";
	sys : Sys;
include "draw.m";
	draw: Draw;
include "rand.m";

Count: module {
	init : fn (ctxt : ref Draw->Context, argv : list of string);
};

init(nil : ref Draw->Context, argv : list of string)
{
	sys = load Sys Sys->PATH;
	if (sys == nil)
		badmod(Sys->PATH);
	draw = load Draw Draw->PATH;
	if (draw == nil)
		badmod(Draw->PATH);
	rand := load Rand Rand->PATH;
	if (rand == nil)
		badmod(Rand->PATH);
	rand->init(sys->millisec());
	msg: string;
	wait := 500 + rand->rand(2000);
	if (tl argv != nil) {
		
		for (val := big hd tl argv; val >= big 0; val--)
				sys->sleep(wait);
		msg = "I counted to "+hd tl argv;
	}
	else
		msg = "no count given!";

	fd := sys->create("Output", sys->OREAD, 8r777 | sys->DMDIR);
	if (fd == nil)
		sys->fprint(sys->fildes(2), "ERR: cannot create Output: %r\n");
	fd = sys->create("Output/output.log", sys->OWRITE, 8r666);
	if (fd != nil)
		sys->fprint(fd, "%s\n", msg);
}

badmod(path: string)
{
	sys->print("Count: failed to load: %s\n",path);
	exit;
}

