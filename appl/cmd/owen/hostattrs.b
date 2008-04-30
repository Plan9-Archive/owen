implement Hostattrs;
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
	sh: Sh;
	Context: import sh;
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "string.m";
	str: String;

Hostattrs: module {
	init: fn();
	getattrs: fn(): Attrs[string];
};

init()
{
	sys = load Sys Sys->PATH;
	sh = load Sh Sh->PATH;
	attributes = load Attributes Attributes->PATH;
	str = load String String->PATH;
}

# attributes:
# memphys=current max
# memswap=current max
# cputype=manufacturer mhz [ncpu]
# ostype=Linux/FreeBSD/Plan9

getattrs(): Attrs[string]
{
	a: Attrs[string];
	# arch device takes precedence, if there.
	if(sys->stat("#a").t0 != -1)
		a = archdevice(a);
	else
	if(sys->stat("#U*/proc/sys").t0 != -1){
		# linux has /proc/sys, etc
		a = procsys(a, "#U*");
		a = meminfo(a, "#U*");
		a = cpuinfo(a, "#U*");
	}else
	if(sys->stat("#U*/dev/cputype").t0 != -1){
		# plan 9 has stuff here and there
		a = plan9(a, "#U*");
	}else{
		# BSD has command line tools
		a  = uname(a);
		a = sysctl(a);
	}
	# could try '#P/cputype' for native.
	return a;
}

procsys(a: Attrs[string], d: string): Attrs[string]
{
	a = a.add("ostype", readfile(d+"/proc/sys/kernel/ostype", 1));
	a = a.add("osrelease", readfile(d+"/proc/sys/kernel/osrelease", 1));
	a = a.add("load", field(1, sys->tokenize(readfile(d+"/proc/loadavg", 1), " ").t1));
	return a;
}

meminfo(a: Attrs[string], d: string): Attrs[string]
{
	(nl, lines) := sys->tokenize(readfile(d+"/proc/meminfo", 0), "\n");
	if(nl < 3)
		return a;
	if((hd lines)[0] == ' ')
		lines = tl lines;		# remove column descriptions
	# lines are in the form:
	# Mem:  526159872 186286080 339873792        0 33308672 68141056
	for(; lines != nil; lines = tl lines){
		(n, toks) := sys->tokenize(hd lines, " ");
		if(n < 2)
			continue;
		case hd toks {
		"Mem:" =>
			a = a.add("memphys", sys->sprint("%q %q", field(2, toks), field(1, toks)));
		"Swap:" =>
			a = a.add("memswap", sys->sprint("%q %q", field(2, toks), field(1, toks)));
		}
	}
	return a;
}

cpuinfo(a: Attrs[string], d: string): Attrs[string]
{
	(nil, lines) := sys->tokenize(readfile(d+"/proc/cpuinfo", 0), "\n");
	cpukind: string;
	mhz: string;
	ncpu := 0;
	for(; lines != nil; lines = tl lines){
		# lines are in the form:
		# cpu MHz		: 1536.856
		(n, toks) := sys->tokenize(hd lines, " \t");
		if(n < 3)
			continue;
		case hd toks {
		"vendor_id" =>
			cpukind = field(2, toks);
		"cpu" =>
			if(hd tl toks == "MHz")
				mhz = field(3, toks);
		"processor" =>
			ncpu++;
		}
	}
	if(ncpu == 0)
		ncpu = 1;
	a = a.add("cputype", sys->sprint("%q %q %d", cpukind, mhz, ncpu));
	return a;
}

plan9(a: Attrs[string], d: string): Attrs[string]
{
	ncpu := 0;
	s := readfile(d+"/dev/sysstat", 0);
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			ncpu++;
	a = a.add("cputype", readfile(d+"/dev/cputype", 1)+" "+string ncpu);
	a = a.add("ostype", "Plan9");
	return a;
}

archdevice(a: Attrs[string]): Attrs[string]
{
	a = a.add("ostype", "Windows");			# XXX should this be "Nt"?
	a = a.add("cputype", readfile("#a/cputype",  1));
	(nil, toks) := sys->tokenize(readfile("#a/hostmem", 0), "\n");
	for(; toks != nil; toks = tl toks){
		memline := str->unquoted(hd toks);
		if(memline != nil)
			a = a.add("mem" + hd memline, str->quoted(tl memline));
	}
	return a;
}

uname(a: Attrs[string]): Attrs[string]
{
	# XXX
	return a;
}

sysctl(a: Attrs[string]): Attrs[string]
{
	# XXX
	return a;
}

oscmd(cmd: list of string): string
{
	ctxt := Context.new(nil);
	ctxt.run(sh->stringlist2list("{x=\"(os $*)}" :: cmd), 0);
	x := ctxt.get("x");
	if(len x != 1)
		return nil;
	return (hd x).word;
}

readfile(f: string, stripnl: int): string
{
	buf := array[8192] of byte;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	if(stripnl && buf[n - 1] == byte '\n')
		n--;
	return string buf[0:n];
}

field(n: int, toks: list of string): string
{
	for(; toks != nil; toks = tl toks)
		if(n-- == 0)
			return hd toks;
	return nil;
}
