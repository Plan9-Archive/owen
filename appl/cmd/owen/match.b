implement Prereq;
include "sys.m";
	sys: Sys;
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "taskgenerator.m";
	Clientspec: import Taskgenerator;
include "filepat.m";
	filepat: Filepat;

pats: list of (int, string, string);
init(argv: list of string): string
{
	sys = load Sys Sys->PATH;
	filepat = load Filepat Filepat->PATH;
	if(filepat == nil)
		return sys->sprint("cannot load %s: %r", Filepat->PATH);
	attributes = load Attributes Attributes->PATH;
	if(attributes == nil)
		return sys->sprint("cannot load %s: %r", Attributes->PATH);
	argv = tl argv;
	if(argv == nil || len argv % 2 != 0)
		return "usage: match attr val [attr val]...";
	for(; argv != nil; argv = tl tl argv)
		pats = (haswild(hd argv), hd argv, hd tl argv) :: pats;
	return nil;
}

ok(c: ref Clientspec): int
{
	m: int;
	for(p := pats; p != nil; p = tl p){
		(wild, a, pat) := hd p;
		(found, v) := c.attrs.fetch(a);
		if(!found && pat != nil)
			return 0;
		if(wild)
			m = filepat->match(pat, v);
		else
			m = v == pat;
		if(m == 0)
			return 0;
	}
	return 1;
}

haswild(s: string): int
{
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '*' || c == '[' || c == '?' || c == '\\')
			return 1;
	}
	return 0;
}
