implement Timetable;
include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "timetable.m";

Infinity: con 16r7fffffff;

Sec2day: con 24*60*60;
EOF, TIME, ALWAYS: con iota;
Blanktm: Daytime->Tm;
Token: adt {
	kind: int;
	period: int;
	start: int;
	duration: int;
};

Lex: adt {
	s: string;
	i: int;
	tzoff: int;
	gettok: fn(l: self ref Lex): Token;
	getc: fn(l: self ref Lex): int;
	ungetc: fn(l: self ref Lex);
	parseerror: fn(l: self ref Lex, e: string);
};

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	daytime = load Daytime Daytime->PATH;
}

new(spec: string): (ref Times, string)
{
	l := ref Lex(spec, 0, daytime->local(daytime->now()).tzoff);
	tm := ref Times;
	for(;;){
		(dates, times) := getline(l);
		if(dates != nil)
			tm.r = (dates, times) :: tm.r;
		if(l.i >= len l.s)
			break;
	} exception e {
	"parse:*" =>
		return (nil, e[6:]);
	}
	return (tm, nil);
}


Times.get(tm: self ref Times, t: int): (int, int)
{
	for(r := tm.r; r != nil; r = tl r){
		(dates, times) := hd r;
		(in0, lim0) := get(dates, t);
		if(in0){
			(in1, lim1) := get(times, t);
			# if limit extends outside current date range,
			# add limit from next appropriate date range.
			if(lim1 >= lim0 && lim1 != Infinity){
				(in2, lim2) := tm.get(lim0);
				if(in2 == in1)
					return (in1, lim2);
				return (in1, lim0);
			}
			return (in1, lim1);
		}
	}
	return (0, Infinity);
}

get(n: ref Range, t: int): (int, int)
{
	# first find out start of period containing t:
	# pt is start of period containing t;
	if(len n.r == 1 && n.r[0] == 0)
		return (1, Infinity);
	pt := 0;
	if(n.period > 0)
		pt = t / n.period * n.period;
	s := 0;
	# XXX could do binary search.
	for(i := 0; i < len n.r; i++){
		t1 := pt + n.r[i];
		if(t < t1)
			return (s, t1);
		s ^= 1;
	}
	# range finishes in next period.
	i = 0;
	if(s){
		if(n.r[0] != 0){
			sys->print("can't happen: start range inconsistent with end\n");
			raise "bad range";
		}
		i++;
	}
	if(n.period == 0)
		return (s, Infinity);
	pt += n.period;
	t1 := pt + n.r[i];
	if(t >= t1){
		sys->print("can't happen: t not in subsequent period, t %d, t1 %d len %d period %d\n", t, t1, len n.r, n.period);
		raise "bad range";
	}
	return (s, t1);
}

geti(a: array of int, i: int): int
{
	if(i >= len a)
		return Infinity;
	return a[i];
}

combine(o: int, r0, r1: ref Range): ref Range
{
	# combine periods of different length by multiplying the smaller
	# period to fit the larger.
	if(r0.period != r1.period){
		if(r0.period > r1.period)
			(r0, r1) = (r1, r0);
		if(r1.period % r0.period != 0){
			sys->print("cannot combine non-multiple periods (%d vs %d)\n", r0.period, r1.period);
			raise "bad period combination";
		}
		m := r1.period / r0.period;
		i := 0;
		a0 := r0.r;
		a: array of int;
		if(len a0 & 1){
			if(a0[0] != 0){
				sys->print("inconsistent range\n");
				raise "bad range";
			}
			a = array[(len a0-1)*m + 1] of int;
			a[i++] = 0;
			a0 = a0[1:];
		}else
			a = array[len a0 * m] of int;
		t := 0;
		if(len a0 > 0){
			for(; i < len a; i += len a0){
				for(j := 0; j < len a0; j++)
					a[i+j] = a0[j] + t;
				t += r0.period;
			}
		}
		r0 = ref Range(r1.period, a);
	}
	(a0, a1) := (r0.r, r1.r);

	a := array[len a0 + len a1 + 1] of int;
	if(len a1 > len a0)
		(a0, a1) = (a1, a0);

	i := 0;
	s := op(o, 0, 0);
	if(s)
		a[i++] = 0;
	s0 := s1 := 0;
	i0 := i1 := 0;
	while(i0 < len a0 || i1 < len a1){
		m: int;
		(x0, x1) := (geti(a0, i0), geti(a1, i1));
		if(x0 <= x1){
			s0 ^= 1;
			i0++;
			m = x0;
		}
		if(x0 >= x1){
			s1 ^= 1;
			i1++;
			m = x1;
		}
		if((ns := op(o, s0, s1)) != s){
			s = ns;
			a[i++] = m;
		}
	}
	if(i == 0)
		a = nil;
	else
		a = a[0:i];
	return ref Range(r0.period, a);
}

op(o: int, a, b: int): int
{
	if(o == Or)
		return a | b;
	if(o == And)
		return a & b;
	return ~a;
}

Lex.getc(l: self ref Lex): int
{
	if(l.i >= len l.s){
		l.i++;
		return -1;
	}
	return l.s[l.i++];
}

Lex.ungetc(l: self ref Lex)
{
	l.i--;
}

Lex.parseerror(nil: self ref Lex, e: string)
{
	raise "parse:"+e;
}

getline(l: ref Lex): (ref Range, ref Range)
{
	period := -1;
	start: int;
	duration: int;
	all := ref Range(7*Sec2day, nil);
	days := ref Range(7*Sec2day, nil);
	hours := ref Range(Sec2day, nil);
	dates := ref Range(0, nil);
	got := 0;
	for(;;){
		t := l.gettok();
		r: ref Range = nil;
		case t.kind {
		'-' =>
			if(period == -1)
				l.parseerror("no start-time for range");
			t = l.gettok();
			if(t.kind != TIME)
				l.parseerror("expected end-time for range");
			if(t.period != period)
				l.parseerror("start and end times for range are of different kinds");
			if(t.duration == Sec2day){
				# daily ranges *include* the end day, unlike time ranges.
				t.start += Sec2day;
			}
			r = mkrange(period, start, t.start);
			period = -1;
		ALWAYS =>
			r = ref Range(0, array[] of {0});
		TIME or
		'\n' or
		EOF or
		'|' =>
			if(period != -1){
				r = mkrange(period, start, start+duration);
				period = -1;
			}
			if(t.kind == TIME)
				(period, start, duration) = (t.period, t.start, t.duration);
		* =>
			l.parseerror(sys->sprint("unexpected token %#q", tok2str(t)));
		}
		if(r != nil){
			if(r.period == 7 * Sec2day)
				days = combine(Or, days, r);
			else if(r.period == Sec2day)
				hours = combine(Or, hours, r);
			else
				dates = combine(Or, dates, r);
			got = 1;
		}
		if(t.kind == '|' || t.kind == '\n' || t.kind == EOF){
			if(len hours.r == 0)
				hours = ref Range(Sec2day, array[] of {0});
			if(len days.r == 0)
				days = ref Range(7*Sec2day, array[] of {0});
			all = combine(Or, all, combine(And, days, hours));
			days = ref Range(7*Sec2day, nil);
			hours = ref Range(Sec2day, nil);
		}
		if(t.kind == '\n' || t.kind == EOF)
			break;
	}
	if(!got)
		return (nil, nil);
	if(len dates.r == 0)
		dates = ref Range(0, array[] of {0});
	return (dates, all);
}

tok2str(t: Token): string
{
	return string t.kind;
}

mkrange(period, start, end: int): ref Range
{
	if(start < 0)
		start += period;
	if(period != 0){
		start %= period;
		end %= period;
	}
	if(start == end)
		return ref Range(period, array[] of {0});
	if(end < start){
		if(period == 0)
			(end, start) = (start, end);
		else
			return ref Range(period, array[] of {0, end, start});
	}
	return ref Range(period, array[] of {start, end});
}

Lex.gettok(l: self ref Lex): Token
{
	for(;;){
		case c := l.getc() {
		-1 =>
			return (EOF, 0, 0, 0);
		' ' or
		'\t' =>
			break;
		'\n' =>
			return ('\n', 0, 0, 0);
		'-' =>
			return ('-', 0, 0, 0);
		'|' =>
			return ('|', 0, 0, 0);
		'#' =>
			while((c = l.getc()) != '\n' && c != EOF)
				;
			l.ungetc();
			break;
		'a' to 'z' or
		'A' to 'Z' or
		'0' to '9' =>
			tok := "";
	Gettok:
			for(;;){
				if(c >= 'A' && c <= 'Z')
					c = c - 'A' + 'a';
				tok[len tok] = c;
				
				case c = l.getc() {
				' ' or
				'\t' or
				'\n' or
				'-' or
				-1 =>
					l.ungetc();
					break Gettok;
				}
			}
			if(tok == "always")
				return (ALWAYS, 0, 0, 0);
			(period, start, duration) := parsetime(l, tok);
			return (TIME, period, start, duration);
		}
	}
}

parsetime(l: ref Lex, tok: string): (int, int, int)
{
	(period, start, duration) := parsetime1(l, tok);
	return (period, start - l.tzoff, duration);
}

parsetime1(l: ref Lex, tok: string): (int, int, int)
{
	# N.B. jan 1st 1970 was a thursday, hence thursday is zero.
	case tok {
	"thursday" or
	"thur" =>
		return (7*Sec2day, 0*Sec2day, Sec2day);
	"friday" or
	"fri" =>
		return (7*Sec2day, 1*Sec2day, Sec2day);
	"saturday" or
	"sat" =>
		return (7*Sec2day, 2*Sec2day, Sec2day);
	"sunday" or
	"sun" =>
		return (7*Sec2day, 3*Sec2day, Sec2day);
	"monday" or
	"mon" =>
		return (7*Sec2day, 4*Sec2day, Sec2day);
	"tuesday" or
	"tue" =>
		return (7*Sec2day, 5*Sec2day, Sec2day);
	"wednesday" or
	"wed" =>
		return (7*Sec2day, 6*Sec2day, Sec2day);
	}
	# formats: 12:30
	# 12/12/2004
	# 2004/12/12

	for(i := 0; i < len tok; i++)
		if(!isdigit(tok[i]))
			break;
	if(i == len tok || i == 0)
		l.parseerror("unknown time format (1)");
	case tok[i] {
	':' =>
		for(j := i+1; j < len tok; j++)
			if(!isdigit(tok[j]))
				break;
		if(j != len tok || tok[j-1] == ':')
			l.parseerror("unknown time format (2)");
		t := int tok*60*60 + int tok[i+1:]*60;
		return (Sec2day, t, 60);
	'/' =>
		(n, toks) := sys->tokenize(tok, "/");
		if(n != 3 || !isnum(hd toks) || !isnum(hd tl toks) || !isnum(hd tl tl toks))
			l.parseerror("unknown date format");
		(d, m, y) := (int hd toks, int hd tl toks, int hd tl tl toks);
		if(d > 1000)
			(d, y) = (y, d);
		if(y < 38)
			y += 2000;
		else if(y < 100)
			y += 1900;
		if(y < 1970 || y >= 2038)
			l.parseerror("invalid year");
		# XXX these checks should be done by Daytime; failing that,
		# we should do better checks here.
		if(m < 1 || m > 12)
			l.parseerror("invalid month");
		if(d < 1 || d > 31)
			l.parseerror("invalid day of month");
		tm := ref Blanktm;
		tm.mday = d;
		tm.mon = m - 1;
		tm.year = y - 1900;
		return (0, daytime->tm2epoch(tm), Sec2day);
	* =>
		l.parseerror("unknown time format (3)");
		raise "blah";		# keep compiler happy
	}
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isnum(s: string): int
{
	for(i := 0; i < len s; i++)
		if(!isdigit(s[i]))
			return 0;
	return 1;
}
