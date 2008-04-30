implement Tst;
include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "draw.m";
include "daytime.m";
	daytime: Daytime;
include "timetable.m";
	timetable: Timetable;
	Times, Range, combine, Or, And: import timetable;
# % % % %  tst2 '2/3/2003 - 24/9/2004 mon-fri'
# nile heartlands sun 21:30

Tst: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};
Blanktm: Daytime->Tm;
init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	timetable = load Timetable Timetable->PATH;
	if(timetable == nil){
		sys->print("cannot load %s: %r\n", Timetable->PATH);
		raise "fail:nope";
	}
	timetable->init();
	daytime = load Daytime Daytime->PATH;
	str = load String String->PATH;

	if(len argv < 2){
		sys->print("args?\n");
		raise "fail:nope";
	}

	(t, nil) := timetable->new(hd tl argv);
	for(r := t.r; r != nil; r = tl r){
		(dates, times) := hd r;
		if(len dates.r > 1){
			for(i := 0; i < len dates.r; i += 2)
				sys->print("%s - %s ", dtext(dates.r[i]), dtext(dates.r[i+1]));
		}
		sys->print("[%s] ", ttext(times.period));
		for(i := 0; i < len times.r; i++)
			sys->print("%s ", ttext(times.r[i]));
		sys->print("\n");
	}

	for(argv = tl tl argv; argv != nil; argv = tl argv){
		(time, e) := parsedate(hd argv);
		if(time == -1){
			sys->print("bad date %#q: %s\n", hd argv, e);
			continue;
		}
		(in, lim) := t.get(time);
		sys->print("%s -> %d %s (%s)\n", dtext(time), in, dtext(lim), ttext(lim-time));
	}
}

dtext(t: int): string
{
	tm := daytime->local(t);
	s: string;
	if(tm.sec != 0 || tm.hour != 0 || tm.min != 0)
		s = daytime->text(tm);
	else
		s = sys->sprint("%.2d/%.2d/%.4d", tm.mday, tm.mon + 1, tm.year + 1900);
	return string t + "(" + s + ")";
}


ttext(t: int): string
{
	if(t == 0)
		return "0";
	s := "";
	if(t > 24*60*60){
		s += string (t / (24*60*60)) + "d";
		t %= 24*60*60;
	}
	if(t > 60*60){
		s += string (t / (60*60)) + "h";
		t %= 60*60;
	}
	if(t > 60){
		s += string (t / 60) + "m";
		t %= 60;
	}
	if(t > 0)
		s += string t + "s";
	return s;
}
		

r2s(r: ref Range): string
{
	s := "["+string r.period+"]";
	for(i := 0; i < len r.r; i++)
		s += " " + string r.r[i];
	return s;
}

parsedate(s: string): (int, string)
{
	date: string;
	(date, s) = str->splitl(s, " ");
	(n, toks) := sys->tokenize(date, "/");
	if(n != 3)
		return (-1, "bad date "+date);
	tm := ref Blanktm;
	tm.mday = int hd toks;
	tm.mon = int hd tl toks - 1;
	y := hd tl tl toks;
	tm.year = int y;
	if(len y <= 2){
		if(tm.year < 70)
			tm.year += 100;
	}else
		tm.year -= 1900;
	s = str->drop(s, " ");
	if(s != nil){
		(n, toks) = sys->tokenize(s, ":.");
		if(n < 2)
			return (-1, "bad time "+s);
		tm.hour = int hd toks;
		tm.min = int hd tl toks;
		if(tl tl toks != nil)
			tm.sec = int hd tl tl toks;
	}
	return (daytime->tm2epoch(tm), nil);
}
