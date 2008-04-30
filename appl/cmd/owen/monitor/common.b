implement Common;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Image, Font, Rect, Display: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "rand.m";
	rand: Rand;
include "string.m";
	str: String;
include "../mount.m";
	mount: Mount;
include "common.m";

display: ref Draw->Display;
schedrootpath := "";
schedrootaddr := "";
schedaddr := "";
sysname := "";
authflag := 0;
keyspec := "";

init(disp: ref Draw->Display, srootpath, srootaddr, saddr: string, hasnoauth: int, keyfile: string)
{
	schedrootpath = srootpath;
	schedrootaddr = srootaddr;
	schedaddr = saddr;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if (draw == nil)
		badmod(Draw->PATH);
	tk = load Tk Tk->PATH;
	if (tk == nil)
		badmod(Tk->PATH);
	tkclient = load Tkclient Tkclient->PATH;
	if (tkclient == nil)
		badmod(Tkclient->PATH);
	tkclient->init();
	rand = load Rand Rand->PATH;
	if (rand == nil)
		badmod(Rand->PATH);
	rand->init(sys->millisec());
	bufio = load Bufio Bufio->PATH;
	if (bufio == nil)
		badmod(Bufio->PATH);
	str = load String String->PATH;
	if (str == nil)
		badmod(String->PATH);
	mount = load Mount Mount->PATH;
	if(mount == nil)
		badmod(Mount->PATH);
	mount->init();
	display = disp;
	sysname = getsysname();
	if(hasnoauth)
		authflag |= Mount->MNOAUTH;
	if(keyfile != nil)
		keyspec = "key="+keyfile+"";

	jobcol = array[] of {
		"#FF0000",
		"#FF8000",
		"#FFFF00",
		"#AAFF00",
		"#00FF80",
		"#00FFFF",
		"#0000FF",
		"#8000FF",
		"#FF66FF",
		"#FFFFFF",
		"#999999",
		"#000000",
	};
}

callresize(butchan: chan of string)
{
	butchan <-= "resize";
}

centrewin(oldtop, top: ref Tk->Toplevel)
{
	ro := tk->rect(oldtop, ".", 0);
	r := tk->rect(top, ".", 0);
	x := ro.min.x + ((ro.dx() - r.dx()) / 2);
	y := ro.min.y + ((ro.dy() - r.dy()) / 2);
	tkcmd(top, ". configure -x "+string x+" -y "+string y);
	tkcmd(top, "update; raise .");
}

jobctlwrite(jobid: int, msg: string): int
{
	return ctlwrite(adminpath + "/" + string jobid, msg);
}

ctlwrite(path, msg: string): int
{
	fd := sys->open(path+"/ctl", sys->OWRITE);
	if (fd == nil){
		error(sys->sprint("failed to open %s/ctl: %r", path), 0);
		return -1;
	}
	if (sys->fprint(fd, "%s", msg) == -1) {
		error(sys->sprint("failed write to %s/ctl: %r", path), 0);
		return -1;
	}
	return 0;
}

dialog(oldtop, top: ref Tk->Toplevel, titlec, chanout: chan of string, butlist: list of (string, string), msg: string, sync: chan of int)
{
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");
	tkcmd(top, "frame .f");
	tkcmd(top, "label .f.l -text {"+msg+"} -font /fonts/charon/plain.normal.font");
	tkcmd(top, "bind .Wm_t <Button-1> +{focus .}");
	tkcmd(top, "bind .Wm_t.title <Button-1> +{focus .}");

	l := len butlist;
	tkcmd(top, "grid .f.l -row 0 -column 0 -columnspan "+string l+" -sticky w -padx 10 -pady 5");
	i := 0;
	retval := array[len butlist] of string;
	for(; butlist != nil; butlist = tl butlist) {
		si := string i;
		tkcmd(top, "button .f.b"+si+" -text {"+(hd butlist).t0+"} -takefocus 0 "+
			"-font /fonts/charon/plain.normal.font -command {send butchan "+si+"}");
		tkcmd(top, "grid .f.b"+si+" -row 1 -column "+si+" -padx 5 -pady 5");
		retval[i] = (hd butlist).t1;
		i++;
	}
	tkcmd(top, "pack .f -padx 10 -pady 10; update");
	centrewin(oldtop, top);
	sync <-= sys->pctl(0, nil);
	tkclient->onscreen(top, "exact");
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	r := "";
	main: for (;;) {
		alt {
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		inp := <- butchan =>
			r = retval[int inp];
			break main;		
		title := <-top.ctxt.ctl or
		title = <-top.wreq or
		title = <-titlec =>
			if (title == "exit")
				break main;
			tkclient->wmctl(top, title);
		}
	}
	chanout <-= "closedialog";
	if (r != nil)
		chanout <-= r;
}

isatback(s, test: string): int
{
	if (len test > len s)
		return -1;
	for (i := len s - len test; i >= 0; i--)
		if (test == s[i:i+len test])
			return i;
	return -1;
}

getext(file: string): string
{
	i := isatback(file, ".");
	if (i == -1)
		return nil;
	return file[i + 1:];
}

getsysname(): string
{
	iobuf := bufio->open("/dev/sysname", bufio->OREAD);
	if (iobuf == nil)
		return nil;
	s := iobuf.gets('\n');
	if (s == nil)
		return nil;
	if (s[len s - 1] == '\n')
		s = s[: len s - 1];
	return s + " (M)";
}

doheading(top: ref Tk->Toplevel, frame, topframe, headingframe: string, startcol: int): array of int
{
	w: int;
	if (headingframe == nil) {
		headingframe = topframe;
		w = int tkcmd(top, topframe+".c cget -width") +
			2 * int tkcmd(top, topframe+".c cget -borderwidth");
	}
	else
		w = max(int tkcmd(top, topframe+".c cget -width"),
			max(int tkcmd(top, frame+" cget -width"),
			int tkcmd(top, headingframe+" cget -width")));
	size := tk->cmd(top, "grid size "+frame);
	(nil, lst) := sys->tokenize(size, " \t\n");
	lastcol := 1 + int hd lst;
#	lastrow := string (int hd tl lst);
#	if (int lastrow <= 0)
#		return nil;
	for (i := 0; i < lastcol; i++) {
#		tkcmd(top, "label "+frame+".ltmp"+string i+" -text { } -bg white");
#		tkcmd(top, "grid "+frame+".ltmp"+string i+
#			" -sticky w -row "+lastrow+" -column "+string i);
		tk->cmd(top, "grid columnconfigure "+frame+" "+string i+" -minsize 0");
		tk->cmd(top, "grid columnconfigure "+headingframe+
			" "+string (startcol+i)+" -minsize 0");
	}

	itemslist := tk->cmd(top, "grid slaves "+frame+" -row 0");
	(nil, ilist) := sys->tokenize(itemslist, " \t\n");
	
	headingslist := tkcmd(top, "grid slaves "+headingframe+" -row 0");
	(n, hlist) := sys->tokenize(headingslist, " \t\n");
	if (len ilist <= len hlist)
		return nil;
	wt := 0;

	aminsize := array[n] of int;
	for (i = 0; i < n; i++) {
		wi := 4 + int tkcmd(top, hd tl ilist+" cget -actx") - int tkcmd(top, hd ilist+" cget -actx");
		wh := 2 + int tkcmd(top, hd hlist+" cget -width");
		ilist = tl ilist;
		hlist = tl hlist;
		maxw := max(wi, wh);
		if (i == n - 1)
			maxw = max(w - wt, maxw);
		tkcmd(top, "grid columnconfigure "+frame+" "+string i+" -minsize "+string maxw);
		tkcmd(top, "grid columnconfigure "+headingframe+
			" "+string (startcol+i)+" -minsize "+string maxw);
		aminsize[i] = maxw;
		wt += maxw;
	}
#	for (i = 0; i < lastcol; i++)
#		tkcmd(top, "destroy "+frame+".ltmp"+string i);
#	tkcmd(top, "grid rowdelete "+frame+" "+lastrow);
	return aminsize;
}

error(s: string, fail: int)
{
	sys->fprint(sys->fildes(2), "Monitor: Error: %s\n",s);
	if (fail)
		raise "fail:error";
}

formatno(n: int): string
{
	sn := string n;
	r := (len sn) % 3;
	s := sn[:r];
	for (i := r; i < len sn; i+=3) {
		if (i != 0)
			s[len s] = ',';
		s += sn[i:i+3];
	}
	return s;
}

getbarimg(): ref Image
{
	barimg := display.newimage(((0,0),(104,BARH)), Draw->RGB24, 0, Draw->White);
	v1 := 238;
	barimg.line((1,1),(1,BARH-2), ED, ED, 0, display.rgb(v1,v1,v1), (0,0));
	barimg.line((102,1),(102,BARH-2), ED, ED, 0, display.rgb(v1,v1,v1), (0,0));
	barimg.line((1,1),(102,1), ED, ED, 0, display.rgb(v1,v1,v1), (0,0));
	barimg.line((1,BARH-2),(102,BARH-2), ED, ED, 0, display.rgb(v1,v1,v1), (0,0));
	s := 107;
	mv := (330-s)/(BARH-4);
	for (i := 0; i < BARH - 4; i++) {
		barimg.line((2,2+i),(101,2+i), ED, ED, 0, display.rgb(s,s,s), (0,0));
		s += mv;
		if (s > 255)
			s = 255;
	}

	return barimg;
}

getcol(i: int): ref Image
{
	h := BARH - 4;
	rgb := array[] of { byte 0, byte 0, byte 0 };
	mv := 160/h;
	startval := byte 125;
	if (i < 2)
		rgb[i] = startval;
	if (i == 2) {
		rgb[1] = startval;
		rgb[2] = startval;
	}
	if (i == 3)
		rgb[2] = startval;

	col := display.newimage(((0,0),(1,h)), Draw->RGB24, 1, Draw->Black);
	for (j := 0; j < h; j++) {
		for (n := 0; n < 3; n++) {
			v := int rgb[n] + mv;
			if (v > 255)
				v = 255;
			rgb[n] = byte v;
		}
		col.writepixels(((0,j),(1,j+1)), rgb);
	}

	return col;
}


kill(pid: int)
{
	if ((fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE)) != nil)
		sys->fprint(fd, "kill");
}

killg(pid: int)
{
	if ((fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE)) != nil)
		sys->fprint(fd, "killgrp");
}

list2array[T](lst: list of T): array of T
{
	a := array[len lst] of T;
	for (i := 0; i < len a; i++) {
		a[i] = hd lst;
		lst = tl lst;
	}
	return a;
}

list2string(l: list of string): string
{
	s := "";
	for (; l != nil; l = tl l)
		s += " " + hd l;
	if (s == nil)
		return nil;
	return s[1:];
}

makescrollbox(top: ref Tk->Toplevel, stype: int, frame: string, x,y: int, args: string, headings: list of (string, string))
{
	tkcmd(top, "frame "+frame);
	cx := string x;
	cy := string y;
	tkcmd(top, "canvas "+frame+".c -yscrollcommand {"+frame+".sb set} "+ args +
		" -relief sunken -yscrollincrement 17 -width "+cx+" -height "+cy);
	tkcmd(top, "scrollbar "+frame+".sb -command {"+frame+".c yview}");

	tkcmd(top, "grid "+frame+".c -column 1 -row 1 "+
		"-sticky ewns -columnspan "+string len headings);
	tkcmd(top, "grid "+frame+".sb -column 0 -row 1 -sticky wns");

	makeheadings(top, 1, stype, frame, headings);
}

makeheadings(top: ref Tk->Toplevel, startcol, stype: int, frame: string, headings: list of (string, string))
{
	i := startcol;
	send := 0;
	for (; headings != nil; headings = tl headings) {
		si := string i++;
		(text, image) := hd headings;
		if (text == nil)
			tkcmd(top, "frame "+frame+".b"+si+" -borderwidth 1 -relief raised ");
		else
			tkcmd(top, "button "+frame+".b"+si+" -anchor w -takefocus 0" +
				" -command {send butchan sort "+string stype+" "+string (send++) +"} "+
				" -text {"+text+"} -borderwidth 1 -relief raised "+font);
		tkcmd(top, "grid "+frame+".b"+si+" -sticky ewns -row 0 -column "+si);
		if (image != nil)
			tkcmd(top, frame+".b"+si+" configure -image "+image+" -anchor center");
	}
}

maparray(data: array of string, lst: list of string): array of int
{
	aout := array[len data] of { * => -1};
	k := 0;
	for (; lst != nil; lst = tl lst) {
		for (i := 0; i < len data; i++) {
			if (hd lst == data[i])
				aout[i] = k;
		}
		k++;
	}
	return aout;
}

max(i1, i2: int): int
{
	if (i1 > i2)
		return i1;
	return i2;
}

min(i1, i2: int): int
{
	if (i1 < i2)
		return i1;
	return i2;
}

minmax(a1, a2: int): (int, int)
{
	if (a1 < a2)
		return (a1, a2);
	return (a2, a1);
}

secondtimer(sync: chan of int)
{
	for (;;) {
		sys->sleep(1000);
		sync <-= 1;
	}
}

sort[T](a: array of T, sortkey, inv: int) for {
	T =>
		cmp: fn (a1, a2: T, sortkey: int): int;
	}
{
	myGT := GT;
	if (inv)
		myGT = -GT;
	mergesort(a, array[len a] of T, sortkey, myGT);
}

mergesort[T](a, b: array of T, sortkey, myGT: int) for {
	T =>
		cmp: fn (a1, a2: T, sortkey: int): int;
	}
{
	r := len a;
	if (r > 1) {
		m := (r-1)/2 + 1;
		mergesort(a[0:m], b[0:m], sortkey, myGT);
		mergesort(a[m:], b[m:], sortkey, myGT);
		b[0:] = a;
		for ((i, j, k) := (0, m, 0); i < m && j < r; k++) {
			if (T.cmp(b[i], b[j], sortkey) == myGT)
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if (i < m)
			a[k:] = b[i:m];
		else if (j < r)
			a[k:] = b[j:r];
	}
}

minsize(top: ref Tk->Toplevel, frame: string)
{
	size := tkcmd(top, "grid size "+frame);
	(nil, lst) := sys->tokenize(size, " \n\t");
	y := int hd tl lst;
	for (i := 0; i < y; i++) {
		l := tkcmd(top, "grid slaves "+frame+" -row "+string i);
		if (l != nil)
			tkcmd(top, "grid rowconfigure "+frame+" "+string i+" -minsize 20");
		else
			tkcmd(top, "grid rowconfigure "+frame+" "+string i+" -minsize 5");
	}
}

mountscheduler(sync: chan of int)
{
	sync <-= sys->pctl(0, nil);
	backoff := 0;
	for(;;){
		if (mountscheduler1()){
			sync <-= 1;
			return;
		}
		if(backoff == 0)
			backoff = 1000 + rand->rand(500) - 250;
		else if(backoff < MAXBACKOFF)
			backoff = backoff * 3 / 2;
		sys->sleep(backoff);
	}
}

mountscheduler1(): int
{
	(ok, s) := mount->mount(schedaddr, schedulepath, Mount->MREPL|authflag, nil, nil, keyspec);
	if(ok == -1){
		sys->fprint(sys->fildes(2), "cannot mount %q: %s\n", schedaddr, s);
		return 0;
	}
	fd := sys->open(schedulepath+"/nodename", sys->OWRITE);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "cannot open %s: %r", schedulepath+"/nodename");
		return 0;
	}
	if (sysname != nil)
		sys->fprint(fd, "%s", sysname);
	return 1;
}

setminsize(top: ref Tk->Toplevel, frame: string, aminsize: array of int)
{
	if (aminsize == nil)
		return;
	for (i := 0; i < len aminsize; i++)
		tkcmd(top, "grid columnconfigure "+frame+" "+
			string i+" -minsize "+string aminsize[i]);
}

sortint(a,b: int): int
{
	if (a > b)
		return GT;
	if (a < b)
		return LT;
	return EQ;
}

sortstring(a,b: string): int
{
	if (a > b)
		return GT;
	if (a < b)
		return LT;
	return EQ;
}

ticker(c, stop: chan of int, interval: int)
{
	n := 0;
	for(;;)alt{
	c <-= n++ =>
		sys->sleep(interval);
	<-stop =>
		exit;
	}
}

tkhandler(top: ref Tk->Toplevel, butchan, titlechan: chan of string)
{
	for (;;) alt {
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		s := <-top.ctxt.ctl or
		s = <-top.wreq or
		s = <-titlechan =>
			if (s == "exit")
				butchan <-= "exit";

			tkclient->wmctl(top, s);
			lst := str->unquoted(s);
			if (lst != nil && hd lst == "!size" && hd tl lst == ".")
				spawn callresize(butchan);
	}
}

badmod(path: string)
{
	sys->print("Common: failed to load: %s\n",path);
	exit;
}

tkcmds(top: ref Tk->Toplevel, a: array of string)
{
	for (i := 0; i < len a; i++)
		tkcmd(top, a[i]);
}

tkcmd(top: ref Tk->Toplevel, cmd: string): string
{
	e := tk->cmd(top, cmd);
	if (e != nil && e[0] == '!')
		sys->print("Monitor: TK Error: %s - '%s'\n",e,cmd);
	return e;
}

reconnect(oldtop, top: ref Tk->Toplevel, chanout: chan of string, sync, killchan: chan of int)
{
	pid := sys->pctl(sys->NEWPGRP, nil);
	sync <-= pid;
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");
	tkcmds(top, reconnectscr);
	tkcmd(top, ".fpopup1.l configure -text {Attempting to reconnect to scheduler     }");
	tkcmd(top, ".fpopup1.l configure -width "+tkcmd(top, ".fpopup1.l cget -width"));
	centrewin(oldtop, top);
	tkclient->onscreen(top, "exact");
	tkclient->startinput(top, "kbd"::"ptr"::nil);

	spawn ticker(tick := chan of int, tickstop := chan[1] of int, 1000);
	spawn mountscheduler(mountc := chan of int);
	mountpid := <-mountc;
	dots := "...";
	loop: for (;;) alt {
		n := <-tick =>
			tkcmd(top, ".fpopup1.l configure -text {Attempting to "+
				"reconnect to scheduler"+ dots[0:n % 4]+"}; update");
		<-killchan =>
			kill(mountpid);
			tickstop <-= 1;
			return;
		inp := <-butchan =>
			case inp {
			"trynow" =>
				kill(mountpid);
			 	spawn mountscheduler(mountc);
				mountpid = <-mountc;
			"exit" =>
				kill(mountpid);
				tickstop <-= 1;
				chanout <-= "closedialog";
				chanout <-= "exit";
				return;
			}
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		s := <-top.ctxt.ctl or
		s = <-top.wreq =>
			tkclient->wmctl(top, s);
		<-mountc =>
			break loop;
	}
	tickstop <-= 1;
	if (schedrootaddr != nil)
		mountschedroot();
	chanout <-= "closedialog";
	chanout <-= "reconnected";
}

mountschedroot()
{
	(ok, s) := mount->mount(schedrootaddr, schedrootpath,
		Mount->MREPL|Mount->MCREATE|authflag, nil, nil, keyspec);
	if(ok == -1)
		sys->fprint(sys->fildes(2), "cannot mount %s: %s", schedrootaddr, s);
}

reconnectscr := array[] of {
	"frame .fpopup -borderwidth 1 -relief raised",
	"frame .fpopup1 -borderwidth 1 -relief sunken",
	"label .fpopup1.l -text { } -anchor w "+font,
	"button .fpopup1.bTry -text {Try Now} -command {send butchan trynow} -takefocus 0"+font,
	"button .fpopup1.bQuit -text {   Quit   } -command {send butchan exit} -takefocus 0"+font,
	"pack .fpopup",
	"grid .fpopup1 -row 0 -column 0 -in .fpopup",
	"grid .fpopup1.l -row 1 -column 0 -padx 20 -pady 10 -columnspan 2",
	"grid .fpopup1.bTry -row 2 -column 0 -padx 10 -pady 10",
	"grid .fpopup1.bQuit -row 2 -column 1 -padx 10 -pady 10",
	"grid rowconfigure .fpopup1 0 -minsize 10",
	"grid rowconfigure .fpopup1 3 -minsize 10",
};

formattime(secs: int): string
{
	n := 0;
	s := "";
	maxbits := 2;
	if (secs >= MONTH) {
		v := secs/MONTH;
		secs = secs - (v*MONTH);
		s += ", " + string v + " mth";
		if (v != 1)
			s[len s] = 's';
		n++;
	}
	if (secs >= WEEK && n < maxbits) {
		v := secs/WEEK;
		secs = secs - (v*WEEK);
		s += ", " + string v + " wk";
		if (v != 1)
			s[len s] = 's';
		n++;
	}
	if (secs >= DAY && n < maxbits) {
		v := secs/DAY;
		secs = secs - (v*DAY);
		s += ", " + string v + " day";
		if (v != 1)
			s[len s] = 's';
		n++;
	}
	if (secs >= HOUR && n < maxbits) {
		v := secs/HOUR;
		secs = secs - (v*HOUR);
		s += ", " + string v + " hr";
		if (v != 1)
			s[len s] = 's';
		n++;
	}
	if (secs >= MIN && n < maxbits) {
		v := secs/MIN;
		secs = secs - (v*MIN);
		s += ", " + string v + " min";
		if (v != 1)
			s[len s] = 's';
		n++;
	}
	if (n < maxbits) {
		s += ", " + string secs + " sec";
		if (secs > 1)
			s[len s] = 's';
	}
	return s[2:];
}

readfile(filename: string): (string, int)
{
	fd := sys->open(filename, sys->OREAD);
	if (fd == nil)
		return (nil, -1);
	buf := array[sys->ATOMICIO] of byte;
	s := "";
	for (;;) {
		i := sys->read(fd, buf, len buf);
		if (i < 0)
			return (s, -1);
		else if (i == 0)
			break;
		s += string buf[:i];
	}
	return (s, 0);
}