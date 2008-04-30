implement NodeMonitor;

#
# Copyright © 2003 Vita Nuova Holdings Limited.  All rights reserved
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Image, Font, Rect, Display: import draw;
include "daytime.m";
	daytime: Daytime;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "format.m";
	format: Format;
	Fmt, Fmtspec, Fmtval, Fmtfile: import format;
include "readdir.m";
	readdir: Readdir;
include "common.m";
	common: Common;
include "arg.m";

NodeMonitor: module {
	init: fn (ctxt: ref Draw->Context, argv: list of string);
};

C: ref Context;

LT: con Common->LT;
EQ: con Common->EQ;
GT: con Common->GT;

NAME, IPADDR, NCONS, DOWNTIME, NCOMPLETED, NFAILED, BLACKLISTED, TIMES, TASKS, ATTRS: con iota;

nodesfmtspecall := array[] of {
	NAME => Fmtspec("name", nil),
	IPADDR => Fmtspec("ipaddr", nil),
	NCONS => Fmtspec("nconnected", nil),
	DOWNTIME => Fmtspec("disconnecttime", nil),
	NCOMPLETED => Fmtspec("ncompleted", nil),
	NFAILED => Fmtspec("nfailed", nil),
	BLACKLISTED => Fmtspec("blacklisted", nil),
	TIMES => Fmtspec("times", nil),
	TASKS => Fmtspec("tasks", array[] of {
				Fmtspec("jobid", nil),
				Fmtspec("taskid", nil),
			}),
	ATTRS => Fmtspec("attrs", array[] of {
				Fmtspec("attr", nil),
				Fmtspec("val", nil),
			}),
};

# Everything except attributes
nodesfmtspecmin := array[] of {
	NAME => Fmtspec("name", nil),
	IPADDR => Fmtspec("ipaddr", nil),
	NCONS => Fmtspec("nconnected", nil),
	DOWNTIME => Fmtspec("disconnecttime", nil),
	NCOMPLETED => Fmtspec("ncompleted", nil),
	NFAILED => Fmtspec("nfailed", nil),
	BLACKLISTED => Fmtspec("blacklisted", nil),
	TIMES => Fmtspec("times", nil),
	TASKS => Fmtspec("tasks",
		array[] of {
			Fmtspec("jobid", nil),
			Fmtspec("taskid", nil),
		}),
};
nodesfmtmin, nodesfmtall: Fmtfile;

nCONNECTED, nNAME, nIP, nCPU, nMEM, nTASKS, nJOB, nTIMESCHEME, nLASTCON, nPACKAGE: con iota;
nGROUP, nNONGROUP, nRUNNING, nNONRUNNING, nALL: con iota;

pNAME, pVERSION: con iota;
ALL, NONE, ADD, DEL: con iota;
NODES, PACKAGES, NSORTS: con iota;

font: con Common->font; 
fontb: con Common->fontb; 
nobg: con Common->nobg; 
adminpath: con Common->adminpath;

display: ref Draw->Display;
maxdowntime := 5 * common->DAY;
autowait := 20;
schedaddr := "";
packages: array of string;
headingheight := 20;

PowerStat: adt {
	inuse, available, offline: int;
};

SortName: adt {
	name: string;
	index: int;
	cmp: fn(a1, a2: ref SortName, nil: int): int;
	getindex: fn(a: array of ref SortName, name: string): int;
};

NodeStatus: adt {
	name, address: string;
	cpu, ncpu, mem: int;
	connections, lastcon, completedtasks, show, inglobal: int;
	blacklisted, selected: int;
	ostype, timescheme: string;
	jobs: array of ref NodeTask;
	cmp: fn (a1, a2: ref NodeStatus, sortkey: int): int;
	packagever: array of string;
	packages: array of ref Package;
};

Package: adt {
	name, version: string;
	cmp: fn(a1, a2: ref Package, sortkey: int): int;
};

NodeTask: adt {
	jobno: int;
	task: int;
};

Context: adt {
	ans: array of ref NodeStatus;
	lastsortmode: array of int;
	invsortmode: array of int;
	dispmode, invert, selectedjob, showallnodes: int;
	aminsize: array of array of int;
	nodesver, auto, visible, firsti, nodesppage,
	maxnodesppage, oneselected: int;
	nodeselecttags: array of string;
	nodestag, nodebindtag: string;
	cpustat: PowerStat;
	new: fn (): ref Context;
};

timeschemes: array of string = nil;

nodeheadings := array[] of {
	" ",
	"Name",
	"IP Address",
	"CPU",
	"Mem",
	"Tasks",
	"Jobs",
	"Time Scheme",
	"Last Connected",
};

nodewidgets := array[] of {
	".nodelimg",
	".nodelname",
	".nodelip",
	".nodelcpu",
	".nodelmem",
	".nodeltasks",
	".nodeftasks",
	".nodeltime",
	".nodellcon",
};

colminsize: array of int;

nodectlicons := array[] of {
	"include",
	"exclude",
	"delnode",
	"refresh",
};

mainscr := array[] of {
	"frame .f",
	"frame .fnode -relief raised",
	"pack .f -fill both -expand 1",
};

edittimescr := array[] of {
	"frame .f",
	"label .f.l -text {Name: }"+fontb,
	"entry .f.e -width 400 -bg white"+font,
	"text .f.t -width 400 -height 350 -bg white"+font,
	"button .f.bdel -text {Delete} -width 50 -command {send butchan delete} -takefocus 0"+font,
	"button .f.bnew -text {New} -width 50 -command {send butchan new} -takefocus 0"+font,
	"button .f.bok -text {OK} -width 50 -command {send butchan ok} -takefocus 0"+font,
	"button .f.bcancel -text {Cancel} -width 50 -command {send butchan cancel} -takefocus 0"+font,
	"frame .f.fb",

	"grid .f.bdel .f.bnew .f.bok .f.bcancel -row 0 -in .f.fb",

	"pack .f -fill both -expand 1",
	"grid .f.l .f.e -row 0 -sticky w -padx 5 -pady 5",
	"grid .f.t -row 1 -column 0 -columnspan 2 -sticky nsew -padx 5",
	"grid .f.fb -row 2 -column 0 -columnspan 2 -padx 5 -pady 5",

	"bind .f.e {<Key-	>} {focus .f.t}",
	"bind .f.t {<Key-	>} {focus .f.bdel}",
	"bind .f.bdel {<Key-	>} {focus .f.bnew}",
	"bind .f.bnew {<Key-	>} {focus .f.bok}",
	"bind .f.bok {<Key-	>} {focus .f.bcancel}",
	"bind .f.bcancel {<Key-	>} {focus .f.e}",
	"focus .f.t",
};

nodedispscr := array[] of {
	"canvas .fnode.c -xscrollcommand {.fnode.sbx set} " +
		" -relief sunken -xscrollincrement 20 -width 50 -height 50 -bg white",
	"scrollbar .fnode.sbx -command {.fnode.c xview} -orient horizontal",
	"scrollbar .fnode.sby -command {send scrollchan} ",
	"panel .fnode.ppwr",
	"label .fnode.lshow -text {(0/0 nodes) } -font /fonts/charon/plain.small.font",
	"label .fnode.lpower -text {Power: 0 Mhz} -font /fonts/charon/plain.small.font",
	"label .fnode.linusel -text { ( Using:} -font /fonts/charon/plain.small.font",
	"label .fnode.lfreel -text { Free:} -font /fonts/charon/plain.small.font",
	"label .fnode.lb -text {)   } -font /fonts/charon/plain.small.font",
	"label .fnode.linuse -text {0%} -font /fonts/charon/plain.small.font -fg #cc2222",
	"label .fnode.lfree -text {0%} -font /fonts/charon/plain.small.font -fg #009900",
#	"frame .fnode.fheading",
	"frame .fnode.fshow",
	"grid .fnode.lpower .fnode.linusel .fnode.linuse "+
		".fnode.lfreel .fnode.lfree .fnode.lb " +
		".fnode.ppwr -in .fnode.fshow -row 0",
	"canvas .fnode.cshow -borderwidth 0 -height 2 -width 2",
	".fnode.cshow create window 0 0 -window .fnode.fshow -anchor ne",
	"grid .fnode.lshow -in .fnode.fshow -row 0 -column 7",

#	".fnode.c create window 0 0 -window .fnode.fheading -anchor nw",
	"grid .fnode.c -row 0 -column 1 -sticky nsew",
	"grid .fnode.sbx -row 1 -column 1 -sticky ewn",
	"grid .fnode.sby -row 0 -column 0 -sticky ns",
	"grid .fnode.cshow -row 2 -column 0 -columnspan 2 -sticky ew",
	"grid rowconfigure .fnode 0 -weight 1",
	"grid columnconfigure .fnode 1 -weight 1",
};

ctlscr := array[] of {
	"frame .fctl1 -borderwidth 1 -relief sunken",
	"frame .fctl -borderwidth 1 -relief raised",
	"frame .fctl.fb",
	"frame .fctl.fb2",
	"frame .fctl.fctl",

#	"menu .mnodes"+font,
#	".mnodes add command -command {send butchan invnodes} -label {Invert Selection}",
#	".mnodes add separator",
#	".mnodes add command -command {send butchan nodebutton include} -label {Include in Global Group}",
#	".mnodes add command -command {send butchan nodebutton exclude} -label {Exclude from Global Group}",
#	".mnodes add separator",
#	".mnodes add command -command {send butchan nodebutton delnode} -label {Remove}",

#	"button .fctl.fb.brefresh -command {send butchan refresh} -text {Refresh} -takefocus 0 "+font,
	"checkbutton .fctl.fb.bauto -command {send butchan auto} -variable auto -text {auto} -takefocus 0 "+font,
	
#	"grid .fctl.fb.bgmenu -row 0 -column 0 -sticky wns",
#	"grid .fctl.fb.brefresh -row 0 -column 2 -sticky wns",
	"grid .fctl.fb.bauto -row 0 -column 4 -sticky w",

	"grid .fctl.fb -row 0 -column 0 -padx 10 -pady 5 -sticky nw",
#	"grid .fctl.fb2 -row 1 -column 0 -padx 10 -pady 5 -sticky nw",
#	"grid .fctl.fctl -row 2 -column 0 -padx 10 -pady 5 -sticky nw",
	"pack .fctl -in .fctl1 -fill x",
};

infoscr := array[] of {
	"frame .finfo1 -borderwidth 1 -relief sunken",
	"frame .finfo -borderwidth 1 -relief raised",
	"label .finfo.lnodeinfo -text {Node Information}"+fontb,
	"label .finfo.llname -text {Name:}"+font,
	"label .finfo.lname -text {} -width 0 -anchor w"+font,
	"label .finfo.llostype -text {OS Type:}"+font,
	"label .finfo.lostype -text {} -width 0 -anchor w"+font,

	"grid .finfo.lnodeinfo -row 0 -column 0 -columnspan 2 -sticky w",
	"grid .finfo.llname -row 1 -column 0 -sticky w",
	"grid .finfo.lname -row 1 -column 1 -sticky ew",
	"grid .finfo.llostype -row 2 -column 0 -sticky w",
	"grid .finfo.lostype -row 2 -column 1 -sticky ew",
	"grid columnconfigure .finfo 1 -weight 1",
	"pack .finfo -in .finfo1 -fill both -expand 1",
};

timescr := array[] of {
	"frame .ftime1 -borderwidth 1 -relief sunken",
	"frame .ftime -borderwidth 1 -relief raised",
	"label .ftime.ltimes -text {Time Schemes} -width 192 -anchor w"+fontb,
	"choicebutton .ftime.cbtime -values {{Always On} {Evenings & Weekends}} -takefocus 0"+font,
	"button .ftime.bapply -text {Apply} -command {send butchan applytimescheme} "+
		"-takefocus 0 -width 80"+font,
	"button .ftime.bedit -text { Edit } -command {send butchan edittimescheme} "+
		"-takefocus 0 -width 80"+font,

	"grid .ftime.ltimes -row 0 -column 0 -columnspan 2 -sticky w",
	"grid .ftime.cbtime -row 1 -column 0 -columnspan 2 -sticky w",
	"grid rowconfigure .ftime 2 -minsize 5",
	"grid .ftime.bapply .ftime.bedit -row 3 -column 0",
	"grid rowconfigure .ftime 4 -minsize 5",
	"pack .ftime -in .ftime1 -fill both -expand 1",
};

jobscr := array[] of {
	"frame .fjob1 -borderwidth 1 -relief sunken",
	"frame .fjob -borderwidth 1 -relief raised",

	"radiobutton .fjob.rball -text {Show all nodes} -variable allnodes -value 1 "+
		"-command {send butchan allnodes} -takefocus 0"+font,
	"radiobutton .fjob.rbopt -text {Show} -variable allnodes -value 0 "+
		"-command {send butchan allnodes} -takefocus 0"+font,

	"label .fjob.ljob -text {Job:} "+font,
	"choicebutton .fjob.cbjob -command {send butchan selectjob} "+
		"-values {} -variable jobindex -takefocus 0"+fontb,

	"frame .fjob.fjobno",
	"label .fjob.ljobno -text {Job Group}"+fontb,

	"choicebutton .fjob.cbdisp -command {send butchan dispmode} "+
		"-values {{group nodes} {non group nodes} "+
		"{running nodes} {non running nodes}} -variable dispmode -takefocus 0"+font,

			
	"button .fjob.bexl -text {Remove from group} -takefocus 0 "+
		"-command {send butchan jobbutton exclude}" + font,

	"button .fjob.binc -text {Add to group} -takefocus 0 "+
		"-command {send butchan jobbutton include}"+ font,

	"grid .fjob.rball -row 1 -column 0 -columnspan 2 -sticky w",


	"grid .fjob.fjobno -row 0 -column 0 -columnspan 2 -sticky w",
	"grid .fjob.ljobno .fjob.cbjob -in .fjob.fjobno -row 0 -sticky w",

	"grid .fjob.rbopt .fjob.cbdisp -row 2 -sticky w",

	"grid rowconfigure .fjob 4 -minsize 5",
	"grid .fjob.binc -row 5 -column 0 -columnspan 2",
	"grid .fjob.bexl -row 6 -column 0 -columnspan 2",
	"grid rowconfigure .fjob 7 -minsize 5",

	"pack .fjob -in .fjob1 -fill both -expand 1",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if (sys == nil)
		badmod(Sys->PATH);
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
	daytime = load Daytime Daytime->PATH;
	if (daytime == nil)
		badmod(Daytime->PATH);
	bufio = load Bufio Bufio->PATH;
	if (bufio == nil)
		badmod(Bufio->PATH);
	str = load String String->PATH;
	if (str == nil)
		badmod(String->PATH);
	sexprs = load Sexprs Sexprs->PATH;
	if (sexprs == nil)
		badmod(Sexprs->PATH);
	sexprs->init();
	format = load Format Format->PATH;
	if (format == nil)
		badmod(Format->PATH);
	format->init();
	readdir = load Readdir Readdir->PATH;
	if (readdir == nil)
		badmod(Readdir->PATH);
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmod(Arg->PATH);
	common = load Common Common->PATH;
	if (common == nil)
		badmod(Common->PATH);

	nodesfmtall = Fmtfile.new(nodesfmtspecall);
	nodesfmtmin = Fmtfile.new(nodesfmtspecmin);

	packagelist: list of string = nil;
	noauth := 0;
	keyfile: string;
	arg->init(argv);
	arg->setusage("nodemonitor [-A] [-a nsecs] [-k keyfile] [-d ndays] [-p package] scheduleraddress");
	while ((opt := arg->opt()) != 0) {
		case opt {
		'A' =>
			noauth = 1;
		'k' =>
			keyfile = arg->earg();
		'a' =>
			autowait = int arg->earg();
			if (autowait < 1)
				arg->usage();
		'd' =>
			ndays := int arg->earg();
			if (ndays < 1)
				arg->usage();
			maxdowntime = ndays * common->DAY;
		'p' =>
			packagelist = arg->earg() :: packagelist;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if (argv == nil || len argv > 2)
		arg->usage();
	schedaddr = hd argv;
	arg = nil;
	sys->pctl(sys->NEWPGRP | Sys->FORKNS, nil);
	
	if (ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	packages = array[len packagelist] of string;
	for (i := len packages - 1; i >= 0; i--) {
		packages[i] = hd packagelist;
		packagelist = tl packagelist;
	}
	common->init(display, "", "", schedaddr, noauth, keyfile);
	updatenodewidgets();
	updatenodeheadings();

	spawn window(ctxt);
}

badmod(path: string)
{
	sys->print("Nodemonitor: failed to load: %s\n",path);
	exit;
}

loadicons(top: ref Tk->Toplevel)
{
	tkcmd(top, "image create bitmap pc -file @/icons/monitor/pc.bit");
	tkcmd(top, "image create bitmap pcoff -file @/icons/monitor/pcoff.bit");
	tkcmd(top, "image create bitmap pcdown -file @/icons/monitor/pcdown.bit");
	tkcmd(top, "image create bitmap pcbl -file @/icons/monitor/pcbl.bit");
	tkcmd(top, "image create bitmap pcoffbl -file @/icons/monitor/pcoffbl.bit");
	tkcmd(top, "image create bitmap pcdownbl -file @/icons/monitor/pcdownbl.bit");
	tkcmd(top, "image create bitmap pcicon -file @/icons/monitor/pcicon.bit");
	for (i := 0; i < len nodectlicons; i++)
		tkcmd(top, "image create bitmap "+nodectlicons[i]+" -file @/icons/monitor/"+
			nodectlicons[i]+".bit -maskfile @/icons/monitor/"+nodectlicons[i]+"mask.bit");
}

window(ctxt: ref Draw->Context)
{
 	i: int;
	C = Context.new();
	(top, title) := tkclient->toplevel(ctxt, "", "Node Monitor", tkclient->Appl);
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");
	scrollchan := chan of string;
	tk->namechan(top, scrollchan, "scrollchan");
	selectnodechan := chan of string;
	tk->namechan(top, selectnodechan, "selectnodechan");

	drawscreen(top);

	barimg := common->getbarimg();
	drawfont := Font.open(display, "/fonts/charon/plain.small.font");
	if (drawfont == nil)
 		error(sys->sprint("could not open /fonts/charon/plain.small.font: %r"), 0);
	powerimg := display.newimage(((0,0),(104,common->BARH)),
				Draw->RGB24, 0, Draw->Black);
	powerimg.draw(barimg.r, barimg, nil, barimg.r.min);
	colinuse := common->getcol(3);
	colfree := common->getcol(1);

	tk->putimage(top, ".fnode.ppwr", powerimg, nil);

	timer := chan of int;
	spawn common->secondtimer(timer);

	tkcmd(top, "variable dispmode "+string nGROUP);
	tkcmd(top, "variable allnodes 1");
	tkcmd(top, "variable auto 1");
	tkcmd(top, "variable invert 0");
	tkcmd(top, "send butchan refresh");
	tkcmd(top, "pack propagate . 0");
	tkcmd(top, ". configure -width 750 -height 550");
	resize(top, C);
	firsttime := 1;
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tcount := 0;
	connected := 1;
	topdialog: ref Tk->Toplevel = nil;
	dialogpid := -1;
	select0, select1: int;
	multiselecting := 0;
	lastnodeid := 0;
	lastnodebut := 0;
	retrykillchan := chan[1] of int;
	lastselectedpos := 9999;
	selectscrollid := 0;

	spawn common->tkhandler(top, butchan, title);
main:
	for (;;) alt {
	inp := <- butchan =>
		if (topdialog != nil) {
			if (inp == "closedialog") {
				tkcmd(top, "raise .; focus .");
				topdialog = nil;
				dialogpid = -1;
			}
			else if (inp == "exit") {
				retrykillchan <-= 1;
				break main;
			}
			else
				break;
		}
		tkcmd(top, "update -disable");
		# sys->print("inp: %s\n", inp);
		(nil, lst) := sys->tokenize(inp, " \t\n");
		case hd lst {
		"readtimeschemes" =>
			gettimeschemes(top);
		"applytimescheme" =>
			names: list of string = nil;
			for (i = 0; i < len C.ans; i++)
				if(C.ans[i].selected)
					names = C.ans[i].name :: names;
			settimescheme(tkcmd(top, ".ftime.cbtime getvalue"), names);
			
		"edittimescheme" =>
			spawn editscheme(ctxt, tkcmd(top, ".ftime.cbtime getvalue"), butchan);					
		"invnodes" =>
			for (i = 0; i < len C.ans; i++)
				C.ans[i].selected = ++C.ans[i].selected % 2;
			updatenodeswin(top, C);
		"alert" =>
			titlec: chan of string;
			sync := chan of int;
			(topdialog, titlec) = tkclient->toplevel(ctxt,
					"", "Alert", tkclient->Popup);
			spawn common->dialog(top, topdialog, titlec, butchan,
					("  Ok  ", nil) :: nil, common->list2string(tl lst), sync);
			dialogpid = <-sync;
		"jobbutton" =>
			jobno := C.selectedjob;
			if (jobno == -1)
				break;
			case hd tl lst {
			"include" =>
				l: list of string = nil;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected)
						l = C.ans[i].name :: l;
				}
				if (l == nil)
					break;
				common->jobctlwrite(jobno, "group add " + str->quoted(l));
				tkcmd(top, "send butchan refresh");
			"exclude" =>
				titlec: chan of string;
				sync := chan of int;
				(topdialog, titlec) = tkclient->toplevel(ctxt,
						"", "Alert", tkclient->Popup);
				spawn common->dialog(top, topdialog, titlec, butchan,
						("Do it now", "jobbutton reallyexclude setgroup") ::
						("Wait", "jobbutton reallyexclude noop") :: nil, 
						"Make group changes immediately or wait\n"+
						"for nodes to finish processing current task?", sync);
				dialogpid = <-sync;
			"reallyexclude" =>
				l: list of string = nil;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected)
						l = C.ans[i].name :: l;
				}
				if (l == nil)
					break;
				common->jobctlwrite(jobno, "group del " + str->quoted(l));
				if (hd tl tl lst == "setgroup")
					common->jobctlwrite(jobno, "setgroup");
				tkcmd(top, "send butchan refresh");					
			}
		"nodebutton" =>
			case hd tl lst {
			"refresh" =>
				refresh(top, C, 0, powerimg, barimg, colinuse, colfree);
				firsttime = 0;
			"include" =>
				l: list of string = nil;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected && !C.ans[i].inglobal)
						l = C.ans[i].name :: l;
				}
				if (l == nil)
					break;
				common->ctlwrite(adminpath, "group add " +
					str->quoted(l));
				common->ctlwrite(adminpath, "setgroup");
				tkcmd(top, "send butchan refresh");
			"exclude" =>
				l: list of string = nil;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected && C.ans[i].inglobal)
						l = C.ans[i].name :: l;
				}
				if (l == nil)
					break;
				common->ctlwrite(adminpath, "group del " +
					str->quoted(l));
				common->ctlwrite(adminpath, "setgroup");
				tkcmd(top, "send butchan refresh");
			"delnode" =>
				l: list of string = nil;
				notdead := 0;
				nconnected := 0;
				n := 0;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected) {
						n++;
						if (C.ans[i].connections == 0) {
							l = C.ans[i].name :: l;
							if (daytime->now() - C.ans[i].lastcon <= maxdowntime)
								notdead++;
						}
						else
							nconnected++;
					}
				}
				if (n == 0)
					break;
				dtitle, msg: string;
				butlist: list of (string, string);
				if (nconnected) {
					dtitle = "Alert";
					msg = "Alert: Connected nodes cannot be removed";
					butlist = ("Ok", nil) :: nil;
				}
				else if (notdead == 0) {
					dtitle = "Confirm";
					msg = "Remove "+string n+" dead node(s)?";
					butlist = ("Ok", "nodebutton reallydel "+
							str->quoted(l)) ::
							("Cancel", nil) :: nil;
				}
				else {
					dtitle = "Warning";
					if (notdead == n)
						msg = "Warning: All of the "+
							string n+" selected node(s) have\n"+
							"been disconnected for less than "+
							string(maxdowntime / common->DAY) +" days";
					else
						msg = "Warning: "+string notdead+" of the "+
							string n+" selected nodes have\n"+
							"been disconnected for less than "+
							string(maxdowntime / common->DAY) +" days";
					butlist = ("Remove", "nodebutton reallydel "+
							str->quoted(l)) ::
							("Cancel", nil) :: nil;

				}
				titlec: chan of string;
				sync := chan of int;
				(topdialog, titlec) = tkclient->toplevel(ctxt,
					"", dtitle, tkclient->Popup);
				spawn common->dialog(top, topdialog, titlec, butchan,
					butlist, msg, sync);
				dialogpid = <-sync;
			"reallydel" =>
				common->ctlwrite(adminpath, "delnode "+common->list2string(tl tl lst));
				tkcmd(top, "send butchan refresh");
			}
			
		"reconnect" =>
			(topdialog, nil) = tkclient->toplevel(ctxt, "", "", tkclient->Plain);
			rsync := chan of int;
			spawn common->reconnect(top, topdialog, butchan, rsync, retrykillchan);
			dialogpid = <-rsync;
			connected = 0;
		"reconnected" =>
			connected = 1;
			refresh(top, C, 0, powerimg, barimg, colinuse, colfree);
		"refresh" =>
			refresh(top, C, 0, powerimg, barimg, colinuse, colfree);
			firsttime = 0;
		"auto" =>
			auto := int tkcmd(top, "variable auto");
			C.auto = auto * autowait;
		"allnodes" =>
			oldshow := C.showallnodes;
			C.showallnodes = int tkcmd(top, "variable allnodes");
			testniljoblist(top, C);
		
			if (oldshow != C.showallnodes)
				shownodes(top, C);
		"selectjob" =>
			oldjob := C.selectedjob;
			C.selectedjob = int tkcmd(top, ".fjob.cbjob getvalue");
			if (!C.showallnodes && oldjob != C.selectedjob)
				shownodes(top, C);
		"dispmode" =>
			dispmode := int tkcmd(top, "variable dispmode");
			oldinv := C.invert;
			if (dispmode == nNONGROUP || dispmode == nNONRUNNING) {
				dispmode--;
				C.invert = 1;
			}
			else
				C.invert = 0;
			if (!C.showallnodes && (dispmode != C.dispmode || oldinv != C.invert)) {
				C.dispmode = dispmode;
				shownodes(top, C);
			}
		"sort" =>
			stype := int hd tl lst;
			sortmode := int hd tl tl lst;
			if (sortmode == C.lastsortmode[stype])
				C.invsortmode[stype] = ++C.invsortmode[stype] % 2;
			else
				C.invsortmode[stype] = 0;
			C.lastsortmode[stype] = sortmode;
			if (stype == NODES) {
				common->sort(C.ans, sortmode, C.invsortmode[stype]);
				updatenodeswin(top, C);
			}
			if (stype == PACKAGES) {
				if (C.oneselected != -1) {
					common->sort(C.ans[C.oneselected].packages, sortmode,
						C.invsortmode[stype]);
					updatepackagelist(top, C);
				}
			}
		"release" =>
			lastselectedpos = 9999;
			selectscrollid = ++selectscrollid % 1024;
			if (multiselecting) {
				multiselecting = 0;
				(select0, select1) = common->minmax(select0, select1);
				select0 += C.firsti;
				select1 += C.firsti;
				# sys->print("firsti: %d (%d %d)\n",C.firsti, select0, select1);
				if (select0 < 0)
					select0 = 0;
				if (select1 >= len C.ans)
					select1 = len C.ans - 1;
				for (i = select0; i <= select1; i++)
					C.ans[i].selected = ++C.ans[i].selected % 2;
				C.oneselected = -1;
				for (i = 0; i < len C.ans; i++) {
					if (C.ans[i].selected) {
						if (C.oneselected == -1)
							C.oneselected = i;
						else {
							C.oneselected = -1;
							break;
						}
					}
				}
				shownodeinfo(top, C);
					
			}
			tkcmd(top, ".fnode.c raise "+C.nodebindtag);
			lastnodeid = 0;		
		"resize" =>
			resize(top, C);
		"exit" =>
			break main;
		}
		tkcmd(top, "update -enable; update");
	inp := <-selectnodechan =>
			if (len C.ans == 0)
				break;
		(nil, lst) := sys->tokenize(inp, " \t\n");
			selectedpos := int hd tl tl lst/20;
			if (selectedpos == lastselectedpos && hd tl lst != "cont")
				break;
		sloop: for (;;) alt {
			inp = <-selectnodechan => ;
			* => break sloop;
		}
		tkcmd(top, "update -disable");

			# sys->print("%s (%d != %d)\n",inp, selectedpos, lastselectedpos);
			# sys->print("inp: %s\n", inp);
			lastselectedpos = selectedpos;
			id, but: int;
			if (hd tl lst == "cont") {
				oldscrollid := int hd tl tl lst;
				# sys->print("\t%d == %d?\n",oldscrollid, selectscrollid);
				if (oldscrollid != selectscrollid)
					break;
				if (lastnodeid < 0 || lastnodeid > C.nodesppage) {
					id = lastnodeid;
					but = lastnodebut;
					lastselectedpos = 9999;
				}
				else
					break;
			}
			else {
				id = selectedpos;
				but = int hd tl lst;
				lastnodeid = id;
				lastnodebut = but;
				selectscrollid = ++selectscrollid % 1024;
			}
			if (id < 0) {
				if (C.firsti > 0) {
					spawn scrollcont(top, selectscrollid);
					diff := -id;
					id += diff;
					if (diff > C.firsti)
						diff = C.firsti;
					select0 += diff;
					C.firsti -= diff;
					# sys->print("selectnode: Updatenodeswin\n");
					updatenodeswin(top, C);
				}
				else
					break;
			}
			else if (id > C.nodesppage) {
				last := len C.ans - 1;
				if (C.firsti + C.nodesppage < last) {
					spawn scrollcont(top, selectscrollid);
					diff := id - C.nodesppage;
					id -= diff;
					if (C.firsti + diff > last - C.nodesppage)
						diff = last - C.nodesppage - C.firsti;
					select0 -= diff;
					C.firsti += diff;
					# sys->print("selectnode: Updatenodeswin\n");
					updatenodeswin(top, C);
				}
				else
					break;
			}
			if (C.firsti + id >= len C.ans)
				id = len C.ans - 1 - C.firsti;
			if (C.ans[C.firsti + id].show == 0)
				break;
			if (but == 1) {
				for (i = 0; i < len C.ans; i++)
					C.ans[i].selected = 0;
				multiselecting = 0;
			}
			if (!multiselecting) {
				select0 = id;
				multiselecting = 1;
			}
			select1 = id;
			# sys->print("select: %d => %d\n", C.firsti + select0, C.firsti + select1);
			selectnode(top, C, select0, select1);

			if (but == 1) {
				C.oneselected = C.firsti + id;
				shownodeinfo(top, C);
			}
		tkcmd(top, "update -enable; update");

	inp := <-scrollchan =>
		where := C.firsti;
		scrollloop: for(;;) {
			# sys->print("\tscrollchan: '%s'\n", inp);
			(nil, lst) := sys->tokenize(inp, " ");
			case hd lst {
			"moveto" =>
				where = int (real C.visible * real hd tl lst);
			"scroll" =>
				val := int hd tl lst;
				if(hd tl tl lst == "page")
					val *= C.nodesppage;
				where += val;
				if (where > C.visible - C.nodesppage)
					where = C.visible - C.nodesppage;
				if (where < 0)
					where = 0;
			}
			alt {
			inp = <-scrollchan => ;
			* =>
				break scrollloop;
			}
		}
		if(where != C.firsti){
			tkcmd(top, "update -disable");
			C.firsti = where;
			updatenodeswin(top, C);
			tkcmd(top, "update -enable; update");
		}
	<-timer =>
		if (topdialog != nil) {
			common->centrewin(top, topdialog);
			tkcmd(topdialog, "focus .");
		}
		if (!connected)
			break;

		tcount++;
		if (C.auto && tcount % C.auto == 0) {
			if (multiselecting)
				break; # Don't try to refresh while the user is selecting nodes
			refresh(top, C, 1, powerimg, barimg, colinuse, colfree);
			tkcmd(top, "update");
			tcount = 0;
		}
	}
	if (dialogpid != -1)
		common->killg(dialogpid);
	common->killg(sys->pctl(0, nil));
}

scrollcont(top: ref Tk->Toplevel, id: int)
{
	sys->sleep(500);
	tkcmd(top, "send selectnodechan selectnode cont "+string id+" x y");
}

shownodeinfo(top: ref Tk->Toplevel, C: ref Context)
{
	id := C.oneselected;

	if (id == -1) {
		tkcmd(top, ".finfo.lname configure -text {}");
		tkcmd(top, ".finfo.lostype configure -text {}");
	}
	else {
		common->sort(C.ans[id].packages, C.lastsortmode[PACKAGES], C.invsortmode[PACKAGES]);
		tkcmd(top, ".finfo.lname configure -text {"+C.ans[id].name+"}");
		tkcmd(top, ".finfo.lostype configure -text {"+C.ans[id].ostype+"}");
	}
	updatepackagelist(top, C);
}

updatepackagelist(top: ref Tk->Toplevel, C: ref Context)
{
	tk->cmd(top, "destroy .fpackages");
	id := C.oneselected;
	if (id != -1) {
		tkcmd(top, "frame .fpackages -bg white");
		tkcmd(top, ".finfo.fdisp.c create window 0 0 -window .fpackages -anchor nw");
		common->setminsize(top, ".fpackages", C.aminsize[PACKAGES]);

		for (i := 0; i < len C.ans[id].packages; i++) {
			si := string i;
			tkcmd(top, "label .fpackages.ln"+si+" -bg white "+
				"-text {"+C.ans[id].packages[i].name+"}"+font);
			tkcmd(top, "label .fpackages.lv"+si+" -bg white "+
				"-text {"+C.ans[id].packages[i].version+"}"+font);
			tkcmd(top, "grid .fpackages.ln"+si+" .fpackages.lv"+si+" -row "+si+" -sticky w");
		}
		tkcmd(top, "frame .fpackages.fl -bg white -width 0 -height 0");
		tkcmd(top, "grid .fpackages.fl -row 0 -column 2");

		tkcmd(top, ".finfo.fdisp.c configure -scrollregion {0 0 "+
			tkcmd(top, ".fpackages cget -width") + " " +
			tkcmd(top, ".fpackages cget -height")+"}");

		C.aminsize[PACKAGES] = common->doheading(top, ".fpackages", ".finfo.fdisp", nil, 1);
	}
}

selectnode(top: ref Tk->Toplevel, C: ref Context, id0, id1: int)
{
	(id0, id1) = common->minmax(id0, id1);
	tkid0 := id0;
	id0 += C.firsti;
	tkid1 := id1;
	id1 += C.firsti;
	w := string common->max(int tkcmd(top, ".fnodes cget -width"),
					int tkcmd(top, ".fnode.c cget -width"));
	id := C.firsti;
	n := common->min(1+C.nodesppage, len C.ans - id);

	for (i := 0; i < n; i++) {
		cmp := 0;
		if (i < tkid0 || i > tkid1)
			cmp = 1;
		if (C.ans[id].selected == cmp)
			selectrow(top, C, C.ans[i].show, i, w);
		else
			selectrow(top, C, 0, i, w);
		id++;
	}
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

job2groupstr(path: string): list of string
{
	groupfile := path +"/group";
	iobuf := bufio->open(groupfile, bufio->OREAD);
	if (iobuf == nil) {
		error(sys->sprint("could not open %s: %r",groupfile), 0);
		return "nil" :: nil;
	}
	s := iobuf.gets('\n');
	if (s == nil) {
		error(sys->sprint("%s is empty",groupfile), 0);
		return "nil" :: nil;
	}
	return str->unquoted(s);
}

shownodes(top: ref Tk->Toplevel, C: ref Context)
{
	jobno := C.selectedjob;
	dispmode := C.dispmode;
	showit := 1 - C.invert;
	if (C.showallnodes) {
		dispmode = nALL;
		showit = 1;
	}
	hideit := 1 - showit;
	case dispmode {
	nALL =>
		for (i := 0; i < len C.ans; i++)
			C.ans[i].show = showit;
		C.visible = showit * len C.ans;
	nGROUP =>
		lst := job2groupstr(adminpath + "/" + string jobno);
		showtype := ALL;
		if (hd lst == "none")
			showtype = NONE;
		else if (hd lst == "+")
			showtype = ADD;
		else if (hd lst == "-")
			showtype = DEL;
		lst = tl lst;
		n := len lst;
		a := common->list2array(lst);
		visible := 0;
		show := showit;
		for (i := 0; i < len C.ans; i++) {
			if (!C.ans[i].inglobal)
				show = hideit;
			else if (showtype == ALL)
				show = showit;
			else if (showtype == NONE)
				show = hideit;
			else {
				showfound := showit;
				if (showtype == DEL)
					showfound = hideit;
				found := 0;
				for(k := 0; k < n; k++) {
					if (C.ans[i].name == a[k]) {
						found = 1;
						a[k] = a[n - 1];
						n--;
						break;
					}
				}
				if (found)
					show = showfound;
				else
					show = 1 - showfound;
			}
			C.ans[i].show = show;
			visible += show;
		}
		C.visible = visible;

	nRUNNING =>
		visible := 0;
		for (i := 0; i < len C.ans; i++) {
			show := hideit;
			for (j := 0; j < len C.ans[i].jobs; j++) {
				if (C.ans[i].jobs[j].jobno == jobno) {
					show = showit;
					break;
				}
			}
			C.ans[i].show = show;
			visible += show;
		}
		C.visible = visible;				

	}
	common->sort(C.ans, C.lastsortmode[NODES], C.invsortmode[NODES]);
	updatenodeswin(top, C);
}

Context.new(): ref Context
{
	lastsort := array[NSORTS] of { * => 0};
	invsort := array[NSORTS] of { * => 0};
	lastsort[NODES] = nNAME;
	lastsort[PACKAGES] = pNAME;
	aminsize: array of array of int;
	dummy: array of int = nil;
	aminsize = array[NSORTS] of { * => dummy };
	return ref Context(nil, lastsort, invsort, 
				nGROUP, 0, -1, -1, aminsize, 
				-1, autowait, 0, 0, 0, -1, 0,
				nil, nil, nil, PowerStat (0,0,0));
}

Package.cmp(a1, a2: ref Package, sortkey: int): int
{
	if (sortkey == pNAME)
		return sortstring(a1.name, a2.name);
	return sortstring(a1.version, a2.version);
}

NodeStatus.cmp(a1, a2: ref NodeStatus, sortkey: int): int
{
	cmp := common->sortint(a2.show, a1.show);
	if (cmp != EQ)
		return cmp;
	case sortkey {
	nCONNECTED =>
		cmp = common->sortint(a1.inglobal, a2.inglobal);
		if (cmp == EQ)
			cmp = common->sortint(a2.blacklisted, a1.blacklisted);
		if (cmp == EQ)
			cmp = sortconnect(a1, a2);
	nTIMESCHEME =>
		cmp = sortstring(a1.timescheme, a2.timescheme);
	nLASTCON =>
		cmp = sortconnect(a1,a2);
	nNAME =>
		return sortnodename(a1, a2);
	nIP =>
		cmp = sortip(a1, a2);
	nCPU =>
		cmp = common->sortint(a1.cpu * a1.ncpu, a2.cpu * a2.ncpu);
		if (cmp == EQ)
			cmp = common->sortint(a1.mem, a2.mem);
	nMEM =>
		cmp = common->sortint(a1.mem, a2.mem);
		if (cmp == EQ)
			cmp = common->sortint(a1.cpu * a1.ncpu, a2.cpu * a2.ncpu);
	nTASKS =>
		cmp = common->sortint(a1.completedtasks, a2.completedtasks);
	nJOB =>
		cmp = common->sortint(len a1.jobs, len a2.jobs);
	* =>
		if (sortkey >= nPACKAGE)
			cmp = sortstring(a1.packagever[sortkey - nPACKAGE], a2.packagever[sortkey - nPACKAGE]);
	}
	if (cmp == EQ)
		cmp = sortnodename(a1,a2);
	return cmp;
}

sortip(a1, a2: ref NodeStatus): int
{
	(nil, l1) := sys->tokenize(a1.address, ".\n!");
	(nil, l2) := sys->tokenize(a2.address, ".\n!");
	for (i := 0; i < 4; i++) {
		if (l1 == nil || l2 == nil)
			return EQ;
		cmp := common->sortint(int hd l1, int hd l2);
		if (cmp != EQ)
			return cmp;
		l2 = tl l2;
		l1 = tl l1;
	}
	return EQ;
}

sortconnect(a1, a2: ref NodeStatus): int
{
	cmp := common->sortint(a1.connections, a2.connections);
	if (cmp == EQ)
		cmp = common->sortint(a1.lastcon, a2.lastcon);
	return cmp;
}

sortnodename(a1, a2: ref NodeStatus): int
{
	if (a1.name < a2.name)
		return LT;
	if (a1.name > a2.name)
		return GT;
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

readnodestatus(C: ref Context, auto: int): int
{
	#t0 := sys->millisec();

	if (len C.ans == 0)
		auto = 0;
	nodesfmt: Fmtfile;
	anames: array of ref SortName;

	if (auto) {
		nodesfmt = nodesfmtmin;
		anames = array[len C.ans] of ref SortName;
		for (i := 0; i < len C.ans; i++)
			anames[i] = ref SortName(C.ans[i].name, i);
	}
	else {
		nodesfmt = nodesfmtall;
		selected: list of int = nil;
		for (i := 0; i < len C.ans; i++) {
			if (C.ans[i].selected)
				selected = i :: selected;
		}
		anames = array[len selected] of ref SortName;
		for (i = 0; selected != nil; selected = tl selected)
			anames[i++] = ref SortName(C.ans[hd selected].name, hd selected);
		C.cpustat = PowerStat (0,0,0);
	}
	common->sort(anames,0,0);
	iobuf := nodesfmt.open(adminpath+"/nodes");

	if (iobuf == nil) {
		error(sys->sprint("could not open %s/nodes: %r",adminpath), 0);
		return 0;
	}

	l: list of ref NodeStatus = nil;
	glist := job2groupstr(adminpath);
	globalgroup := ALL;
	if (hd glist == "none")
		globalgroup = NONE;
	else if (hd glist == "+")
		globalgroup = ADD;
	else if (hd glist == "-")
		globalgroup = DEL;

	glist = tl glist;
	agroup := array[len glist] of ref SortName;
	for (i := 0; glist != nil; glist = tl glist)
		agroup[i++] = ref SortName(hd glist, 0);
	common->sort(agroup,0,0);
	
	for (;;) {
		(v, err) := nodesfmt.read(iobuf);
		if (v == nil){
			if(err != nil)
				error("error reading nodes: "+err, 0);
			break;
		}
		if (auto) {
			k := SortName.getindex(anames, v[NAME].text());
			if (k == -1)
				return readnodestatus(C, 0);
			if (C.ans[k].name != v[NAME].text())
				sys->print("'%s' != '%s'\n", C.ans[k].name, v[NAME].text());
			C.ans[k].connections = int v[NCONS].text();
			C.ans[k].lastcon = daytime->now() - int (big v[DOWNTIME].text()/big 1000);
			C.ans[k].completedtasks = int v[NCOMPLETED].text();
			C.ans[k].blacklisted = int v[BLACKLISTED].text();
			C.ans[k].timescheme = v[TIMES].text();
			if (v[DOWNTIME].text() == "never")
				C.ans[k].lastcon = -1;
			va := v[TASKS].recs;
			C.ans[k].jobs = array[len va] of ref NodeTask;
			for (i = 0; i < len C.ans[k].jobs; i++)
				C.ans[k].jobs[i] = ref NodeTask(int va[i][0].text(), int va[i][1].text());
		}
		else {
			ns := ref NodeStatus(
				v[NAME].text(),
				v[IPADDR].text(),
				-1,
				1,
				-1,
				int v[NCONS].text(),
				daytime->now() - int (big v[DOWNTIME].text()/big 1000),
				int v[NCOMPLETED].text(),
				1,
				1,
				int v[BLACKLISTED].text(),
				0,
				"Unknown",
				v[TIMES].text(),
				nil,
				array[len packages] of string,
				nil
			);
			
			if (v[DOWNTIME].text() == "never")
				ns.lastcon = -1;
			va := v[TASKS].recs;
			ns.jobs = array[len va] of ref NodeTask;
			for (i = 0; i < len ns.jobs; i++)
				ns.jobs[i] = ref NodeTask(int va[i][0].text(), int va[i][1].text());

			va = v[ATTRS].recs;
			attrs := array[len va] of (string, string);
			for(i = 0; i < len va; i++)
				attrs[i] = (va[i][0].text(), va[i][1].text());
			cpu := getattrval(attrs, "cputype");
			if (cpu != nil) {
				lcpu := str->unquoted(cpu);
				if (len lcpu > 1) {
					ns.cpu = int hd tl lcpu;
					
					if (len lcpu > 2)
						ns.ncpu = int hd tl tl lcpu;
					pcpu := ns.cpu * ns.ncpu;
					if (ns.connections == 0)
						C.cpustat.offline += pcpu;
					else if (len ns.jobs == 0)
						C.cpustat.available += pcpu;
					else
						C.cpustat.inuse += pcpu;
				}
			}
			mem := getattrval(attrs, "memphys");
			if (mem != nil) {
				lmem := str->unquoted(mem);
				if (len lmem > 1)
					ns.mem = int (big hd tl lmem / big (1024 * 1024));
			}
			for (i = 0; i < len packages; i++) {
				version := getattrval(attrs, "version_"+packages[i]);
				if (version == nil)
					ns.packagever[i] = nil;
				else
					ns.packagever[i] = getversion(version);
			}
			packagelist: list of (string, string) = nil;
			for (i = 0; i < len attrs; i ++) {
				a := attrs[i].t0;
				if (len a > 8 && a[0:8] == "version_")
					packagelist = (a[8:], attrs[i].t1[:8]) :: packagelist;
			}
			ns.packages = array[len packagelist] of ref Package;
			for (i = 0; i < len ns.packages; i++) {
				ns.packages[i] = ref Package((hd packagelist).t0, (hd packagelist).t1);
				packagelist = tl packagelist;
			}	
			ns.ostype = getattrval(attrs, "ostype");
			if (ns.ostype == nil)
				ns.ostype = "Unknown";
			
			if (SortName.getindex(anames, ns.name) != -1)
				ns.selected = 1;

			l = ns :: l;
		}
	}

	if (!auto) {
		C.ans = array[len l] of ref NodeStatus;
		for (i = 0; l != nil; l = tl l)
			C.ans[i++] = hd l;
	}

	if (globalgroup == ALL) {
		for (i = 0; i < len C.ans; i++)
			C.ans[i].inglobal = 1;
	}
	else if (globalgroup == NONE) {
		for (i = 0; i < len C.ans; i++)
			C.ans[i].inglobal = 0;
	}
	else {
		inlist := 1;
		notinlist := 0;
		if (globalgroup == DEL) {
			inlist = 0;
			notinlist = 1;
		}
		for (i = 0; i < len C.ans; i++) {
			if (SortName.getindex(agroup, C.ans[i].name) == -1)
				C.ans[i].inglobal = notinlist;
			else
				C.ans[i].inglobal = inlist;
		}
	}
	# t1 := sys->millisec();
	# sys->print("Readnodes: %dms\n",t1-t0);
	return 1;
}

getversion(f: string): string
{
#	Just return first 8 characters of MD5 sum
	return f[:8];
#	for(i := len f - 1; i >= 0; i--)
#		if(f[i] == '.')
#			break;
#	if(i == len f - 1 || f[i+1] < '0' || f[i+1] > '9')
#		return -1;
#	return int f[i+1:];
}

getattrval(a: array of (string, string), attr: string): string
{
	for (i := 0; i < len a; i++)
		if (a[i].t0 == attr)
			return a[i].t1;
	return nil;
}

formatmem(i: int): string
{
	if (i < 0)
		return "-";
	return string i +" Mb";
}

formatcpu(spd, n: int): string
{
	if (spd < 0)
		return "-";
	s := "";
	if (spd < 1000)
		s = string spd+"Mhz";
	else
		s = sys->sprint("%.1fGhz", real spd / 1000.0);
	if (n != 1)
		s = string n + "x" + s;
	return s;
}

formatver(s: string): string
{
	if (s == nil)
		return "Not Installed";
	return s;
}

lcon2str(ns: ref NodeStatus): string
{
	if (ns == nil)
		return nil;
	if (ns.connections > 0)
		return "Now";
	if (ns.lastcon == -1)
		return "Never";
	lcon := daytime->text(daytime->local(ns.lastcon));
	return lcon[:len lcon - 12];
}

doscrollbary(top: ref Tk->Toplevel, C: ref Context)
{
	if (C.visible == 0) {
		tkcmd(top, ".fnode.sby set 0 1");
		return;
	}
	p := real C.nodesppage / real C.visible;
	a := real C.firsti / real C.visible;
	b := a + p;
	if (b > 1.0) {
		a -= (b - 1.0);
		if (a < 0.0)
			a = 0.0;
		C.firsti = int (real C.visible * a);
		b = 1.0;
	}
	s := ".fnode.sby set 0"+string a+" 0"+string b;
	tkcmd(top, s);
}

selectrow(top: ref Tk->Toplevel, C: ref Context, select, row: int, w: string)
{
	if (select) {
		if (C.nodeselecttags[row] == nil) {
			C.nodeselecttags[row] = tkcmd(top, ".fnode.c create "+
				"window 0 "+string (1+(20*(1+row)))+
				" -window .fselectnode"+string row+" -anchor nw");
			tkcmd(top, ".fselectnode"+string row+" configure -width "+w);
		}
	}
	else {
		if (C.nodeselecttags[row] != nil) {
			tkcmd(top, ".fnode.c delete "+C.nodeselecttags[row]);
			C.nodeselecttags[row] = nil;
		}
	}
}

updatenodeswin(top: ref Tk->Toplevel, C: ref Context)
{
	i: int;
#	tk->cmd(top, "destroy "+tk->cmd(top, "grid slaves .fnodes"));
#	tk->cmd(top, "destroy .fnodes");
#	tkcmd(top, "frame .fnodes ");
#	hy := tkcmd(top, ".fnode.fheading cget -height");
	if (C.nodestag == nil)
		C.nodestag = tkcmd(top, ".fnode.c create window 0 0 -window .fnodes -anchor nw");
	doscrollbary(top, C);

	for (i = 0; i < len C.nodeselecttags; i++) {
		if (C.nodeselecttags[i] != nil)
			tkcmd(top, ".fnode.c delete "+C.nodeselecttags[i]);
	}
	C.nodeselecttags = array[1+C.nodesppage] of { * => "" };

	row := 0;
	i = C.firsti;
	for (;;) {
		si := string row;
		if (row > C.nodesppage)
			break;
		else if (i >= len C.ans) {
			tkcmd(top, ".nodelimg"+si+" configure -image {}");
			tkcmd(top, ".nodellcon"+si+" configure -text {}");
			tkcmd(top, ".nodelname"+si+" configure -text {}");
			tkcmd(top, ".nodelip"+si+" configure -text {}");
			tkcmd(top, ".nodelcpu"+si+" configure -text {}");
			tkcmd(top, ".nodelmem"+si+" configure -text {}");
			tkcmd(top, ".nodeltasks"+si+" configure -text {}");
			tkcmd(top, ".nodeltime"+si+" configure -text {}");
			for (pv := 0; pv < len packages; pv++)
				tkcmd(top, ".nodelver"+string pv + "_"+si+" configure -text {}");

			tk->cmd(top, "destroy "+tkcmd(top, "pack slaves .nodeftasks"+si));
			row++;
		}			
		else if (C.ans[i].show) {
			fgcol := " -fg black ";
			fgred := " -fg red ";
			if (!C.ans[i].inglobal) {
				fgcol = " -fg #A0A0A0 ";
				fgred = " -fg red*0.5 ";
			}
			imgex := "";
			if (C.ans[i].blacklisted)
				imgex = "bl";
			if (C.ans[i].connections > 0) {
				tkcmd(top, ".nodelimg"+si+" configure -image pc"+imgex);
				tkcmd(top, ".nodellcon"+si+" configure -text {}");
			}
			else {
				if (daytime->now() - C.ans[i].lastcon > maxdowntime) {
					tkcmd(top, ".nodelimg"+si+" configure -image pcdown"+imgex);
					tkcmd(top, ".nodellcon"+si+" configure -text {"+
						lcon2str(C.ans[i])+"}"+fgred);				
				}
				else {
					tkcmd(top, ".nodellcon"+si+" configure -text {"+
						lcon2str(C.ans[i])+"} "+fgcol);
					tkcmd(top, ".nodelimg"+si+" configure -image pcoff"+imgex);
				}
			}
			tkcmd(top, ".nodelname"+si+" configure -text {"+C.ans[i].name+"}"+fgcol);
			tkcmd(top, ".nodelip"+si+" configure -text {"+C.ans[i].address+"}"+fgcol);
			tkcmd(top, ".nodelcpu"+si+" configure -text {"+
				formatcpu(C.ans[i].cpu, C.ans[i].ncpu)+"}"+fgcol);
			tkcmd(top, ".nodelmem"+si+" configure -text {"+
				formatmem(C.ans[i].mem)+"}"+fgcol);
			tkcmd(top, ".nodeltasks"+si+" configure -text {"+
				string C.ans[i].completedtasks+"}"+fgcol);
			tkcmd(top, ".nodeltime"+si+" configure -text {"+C.ans[i].timescheme+"}"+fgcol);

			for (pv := 0; pv < len packages; pv++)
				tkcmd(top, ".nodelver"+string pv+"_"+si+" configure -text {"+
					formatver(C.ans[i].packagever[pv])+"}"+fgcol);

			tk->cmd(top, "destroy "+tkcmd(top, "pack slaves .nodeftasks"+si));
			for (k := 0; k < len C.ans[i].jobs; k++) {
				jobno := C.ans[i].jobs[k].jobno;
				f := ".nodeftasks"+si+".fjob"+string k;
				fl := ".nodeftasks"+si+".ljob"+string k;
				tkcmd(top, "frame "+f+" -borderwidth 1 -relief raised "+
					"-bg "+common->jobcol[jobno % len common->jobcol]+
					" -width 6 -height 6");
				tkcmd(top, "label "+fl+" -height 20 -text {"+string jobno+": "+
					string C.ans[i].jobs[k].task+"} -bg white"+font+fgcol);

				tkcmd(top, "pack "+f+" -side left -padx 4 -pady 4");
				tkcmd(top, "pack "+fl+" -side left");
			}
			if (len C.ans[i].jobs == 0) {
				tkcmd(top, "label .nodeftasks"+si+".fjob0 -height 20 -width 1 -bg white");
				tkcmd(top, "pack .nodeftasks"+si+".fjob0");
			}
			row++;
		}
		i++;
	}
	
	# Ignore:	1st col (never changes width)
	#		Last col (nothing follows it)
	#		Jobs col (no 6) in case we end up with loads of jobs in a column by mistake
	for (i = 1; i < len nodewidgets - 1; i++) {
		if (i == 6)
			continue;
		colminsize[i] = common->max(colminsize[i], 
						int tkcmd(top, ".fnodes.fcol"+string i+" cget -width"));
		tkcmd(top, ".fnodes.fcol"+string i+".bheading configure -width "+
			string (colminsize[i] - 2));
	}

	tkcmd(top, ".fnode.lshow configure -text {"+
		"   ("+string C.visible+"/"+string len C.ans+" nodes)}");

#	common->doheading(top, ".fnodes", ".fnode", ".fnode.fheading", 0);

	w := string common->max(int tkcmd(top, ".fnodes cget -width"),
					int tkcmd(top, ".fnode.c cget -width"));

	if (len C.ans > 0) {
		i = C.firsti;
		n := common->min(C.nodesppage+1, len C.ans - C.firsti);
		for (j := 0; j < n; j++) {
			###############
			C.ans[i].selected = C.ans[i].selected & C.ans[i].show;
			selectrow(top, C, C.ans[i].selected, j, w);
			###############
			#selectrow(top, C, C.ans[i].selected & C.ans[i].show, j, w);
			i++;
		}
	}
	h := tkcmd(top, ".fnodes cget -height");
	tkcmd(top, ".fnode.c configure -scrollregion {0 0 "+ w + " " + h + "}");

	if (C.nodebindtag == nil) {
		tkcmd(top, "frame .fnodebind -bg #00000000 -width "+w+" -height "+h);
		tkcmd(top, "bind .fnodebind <Button-1>"+
			" {send selectnodechan selectnode 1 %y}");
		tkcmd(top, "bind .fnodebind <Button-2> "+
			"{send selectnodechan selectnode 2 %y}");
		tkcmd(top, "bind .fnodebind <Button-3> "+
			"{send selectnodechan selectnode 2 %y}");
		tkcmd(top, "bind .fnodebind <ButtonRelease> "+
			"{send butchan release}");

		C.nodebindtag = tkcmd(top, ".fnode.c create window 0 "+
						string headingheight+" -window .fnodebind -anchor nw");
	}
	else
		tkcmd(top, ".fnodebind configure -width "+w+" -height "+h);
	tkcmd(top, ".fnode.c raise "+C.nodebindtag);
}

resize(top: ref Tk->Toplevel, C: ref Context)
{
	w := 4 + int tkcmd(top, ".fnode.c cget -actwidth");
	tkcmd(top, ".fnode.cshow configure -scrollregion {-"+string w+" 0 0 0}");
	tkcmd(top, "update");
	C.nodesppage = ((int tkcmd(top, ".fnode.c cget -actheight") - headingheight) / 20);
	if (C.nodesppage < 0)
		C.nodesppage = 0;
	if (C.nodesppage > C.maxnodesppage) {
		for (i := 1 + C.maxnodesppage; i <= C.nodesppage; i++) {
			si := string i;
			tkcmd(top, "frame .fselectnode"+si+
				" -bg blue*0.25 -height 20 -width 200");
			tkcmd(top, "label .nodelimg"+si+" -bg white -height 20");
			tkcmd(top, "label .nodellcon"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodelname"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodelip"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodelcpu"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodelmem"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodeltasks"+si+font+" -bg white -height 20");
			tkcmd(top, "label .nodeltime"+si+font+" -bg white -height 20");
			tkcmd(top, "frame .nodeftasks"+si+" -bg white");
			for (pv := 0; pv < len packages; pv ++)
				tkcmd(top, "label .nodelver"+string pv+"_"+si+font+" -bg white -height 20");				for (j := 0; j < len nodewidgets; j++)
				tkcmd(top, "pack "+nodewidgets[j]+si+" -in .fnodes.fcol"+string j+
					" -side top -anchor w");
		}
		C.maxnodesppage = C.nodesppage;
	}
	updatenodeswin(top, C);
	tkcmd(top, "update");
}

drawscreen(top: ref Tk->Toplevel)
{
	i: int;
	loadicons(top);
	tkcmds(top, mainscr);
	tkcmds(top, ctlscr);
	tkcmds(top, infoscr);
	tkcmds(top, timescr);
	tkcmds(top, jobscr);
	tkcmd(top, ".fjob.binc configure -width " + tkcmd(top, ".fjob.bexl cget -width"));

	col := 0;
	for (i = 0; i < len nodectlicons; i++) {
		sc := string col;
		tkcmd(top, "button .fctl.fb.b"+sc+" -takefocus 0"+
			" -command {send butchan nodebutton "+
			nodectlicons[i]+"} -image "+nodectlicons[i]);
		tkcmd(top, "grid .fctl.fb.b"+sc+" -sticky w -row 0 -column "+sc);
		col++;
	}
	tkcmd(top, "grid columnconfigure .fctl.fb "+string (col - 2)+" -minsize 40");
	tkcmds(top, nodedispscr);
	tkcmd(top, ".fnode.cshow configure -height "+
		tkcmd(top, ".fnode.fshow cget -height"));
	tkcmd(top, "frame .fnodes -bg white");

	for (j := 0; j < len nodewidgets; j++) {
		tkcmd(top, "frame .fnodes.fcol"+string j+" -bg white");
		tkcmd(top, "grid .fnodes.fcol"+string j+
			" -sticky nw -row 0 -column "+string j);
		tkcmd(top, "button .fnodes.fcol"+string j+".bheading -takefocus 0 "+
			"-borderwidth 1 -text {"+nodeheadings[j]+"} -anchor w -height 20 "+
			"-command {send butchan sort "+string NODES+" "+string j +"}"+font);
		tkcmd(top, "pack .fnodes.fcol"+string j+".bheading -in .fnodes.fcol"+string j+
					" -side top -fill x -expand 1");
	}
	tkcmd(top, ".fnodes.fcol0.bheading configure -image pcicon -anchor center");
	headingheight = 2 + int tkcmd(top, ".fnodes.fcol0.bheading cget -height");

#	headings: list of (string, string) = nil;
#	for (pv := len packages - 1; pv >= 0; pv--) {
#		name := packages[pv] + " Version";
#		name[0] += 'A' - 'a';
#		headings = (name, nil) :: headings;
#	}
#	headings = ("Online","pcicon") :: ("Name", nil) :: ("IP Address", nil) :: ("Cpu", nil) ::
#				("Mem", nil) :: ("Tasks", nil) :: ("Jobs", nil) :: ("Time Scheme", nil) ::
#				("Last Connected", nil) :: headings;
#	common->makeheadings(top, 0, NODES, ".fnode.fheading",  headings);

	common->makescrollbox(top, PACKAGES, ".finfo.fdisp", 170, 100,
				  "-bg white -borderwidth 2", ("Package", nil) :: ("Version", nil) :: nil);
	tkcmd(top, "grid rowconfigure .finfo.fdisp 1 -weight 1");
	# tkcmd(top, "grid columnconfigure .finfo.fdisp 1 -weight 1");
	tkcmd(top, "grid .finfo.fdisp -row 4 -column 0 -columnspan 2 -sticky nsew -pady 5");

	tkcmd(top, "frame .f.fright");
	tkcmd(top, "pack .fctl1 -in .f.fright -side top -fill x");
	tkcmd(top, "pack .fjob1 -in .f.fright -side top -fill x -pady 10");
	tkcmd(top, "pack .finfo1 -in .f.fright -side top -fill x");
	tkcmd(top, "pack .ftime1 -in .f.fright -side top -fill x -pady 10");
	
	tkcmd(top, "pack .fnode -in .f -padx 10 -pady 10 -fill both -expand 1 -side left");
	tkcmd(top, "pack .f.fright -padx 10 -pady 10 -fill y -expand 0 -side left");

#	hctl := int tkcmd(top, ".fctl cget -height");
#	h := int tkcmd(top, ".f cget -height");
#
#	wt := int tkcmd(top, ". cget -width");
#	ht := int tkcmd(top, ". cget -height");
#	w := int tkcmd(top, ".f cget -width");
#	h = int tkcmd(top, ".f cget -height");
#	diffx = wt - w;
#	diffy = ht - h;
	
	gettimeschemes(top);
}

refresh(top: ref Tk->Toplevel, C: ref Context, auto: int,
	powerimg, barimg, colinuse, colfree: ref Image)
{
	(n, nil) := sys->stat(adminpath);
	if (n == -1) {
		# sys->print("stat2 %s failed, reconnecting: %r\n", adminpath);
		tkcmd(top, "send butchan reconnect");
		return;
	}

	getjobnumbers(top, C);
	
	if (readnodestatus(C, auto)) {
		totalcpu := C.cpustat.inuse + C.cpustat.available + C.cpustat.offline;
		pcinuse := C.cpustat.inuse * 100 / common->max(totalcpu,1);
		pcfree := C.cpustat.available * 100 / common->max(totalcpu,1);
		tkcmd(top, ".fnode.lpower configure -text {Power: "+formatcpu(totalcpu, 1) + "}");
		tkcmd(top, ".fnode.linuse configure -text {"+string pcinuse + "%}");
		tkcmd(top, ".fnode.lfree configure -text {"+string pcfree + "%}");
	
		powerimg.draw(barimg.r, barimg, nil, barimg.r.min);
		powerimg.draw(((2,2),(2+pcinuse,common->BARH-2)), colinuse, nil, (0,0));
		powerimg.draw(((2+pcinuse,2),(2+pcinuse+pcfree,common->BARH-2)), colfree, nil, (0,0));
		tkcmd(top, ".fnode.ppwr dirty");
		shownodes(top, C);	
	}
	gettimeschemes(top);
}

getjobnumbers(top: ref Tk->Toplevel, C: ref Context)
{
	(dirs, nil) := readdir->init(adminpath, readdir->NAME | readdir->COMPACT);
	jobs := "";
	index := 0;
	for (i := 0; i < len dirs; i++) {
		if (isnumber(dirs[i].name[0])) {
			if (int dirs[i].name == C.selectedjob)
				index = i;
			jobs += " {"+dirs[i].name+"}";
		}
	}
	tkcmd(top, ".fjob.cbjob configure -values {"+jobs+"}");
	if(len jobs > 0)
		tkcmd(top, ".fjob.cbjob set "+string index);
	testniljoblist(top, C);
}

testniljoblist(top: ref Tk->Toplevel, C: ref Context)
{
	if (int tkcmd(top, ".fjob.cbjob valuecount") == 0) {
		C.showallnodes = 1;
		tkcmd(top, "variable allnodes 1");
	}
	else
		C.selectedjob = int tkcmd(top, ".fjob.cbjob getvalue");
}

isnumber(c: int): int
{
	return (c >= '0' && c <= '9');
}

error(s: string, fail: int)
{
	sys->fprint(sys->fildes(2), "Nodemonitor: Error: %s\n",s);
	if (fail)
		raise "fail:error";
}

updatenodewidgets()
{
	lnw := len nodewidgets;
	a := array[lnw + len packages] of string;
	for (i := 0; i < lnw; i++)
		a[i] = nodewidgets[i];
	for (i = 0; i < len packages; i++)
		a[i + lnw] = ".nodelver"+string i+"_";
	nodewidgets = a;
	colminsize = array[len nodewidgets] of { * => 0};
}

updatenodeheadings()
{
	lnh := len nodeheadings;
	a := array[lnh + len packages] of string;
	for (i := 0; i < lnh; i++)
		a[i] = nodeheadings[i];
	for (i = 0; i < len packages; i++) {
		a[i + lnh] = packages[i]+" ver.";
		if (a[i + lnh][0] >= 'a' && a[i + lnh][0] <= 'z')
			a[i + lnh][0] += 'A' - 'a';
	}
	nodeheadings = a;
}

gettimeschemes(top: ref Tk->Toplevel)
{
	schemes := "";
	selected := 0;
	selectedtext := tkcmd(top, ".ftime.cbtime getvalue");
	(dirs, nil) := readdir->init(adminpath + "/times", readdir->NAME | readdir->COMPACT);
	timeschemes = array[len dirs] of string;
	for (i := 0; i < len dirs; i++) {
		timeschemes[i] = dirs[i].name;
		schemes += " " + tk->quote(dirs[i].name);
		if (dirs[i].name == selectedtext)
			selected = i;
	}
	tkcmd(top, ".ftime.cbtime configure -values {"+schemes+"}");
	if(len dirs > 0)
		tkcmd(top, ".ftime.cbtime set "+string selected);
}

settimescheme(scheme: string, names: list of string)
{
	if (names == nil)
		return;
	common->ctlwrite(adminpath, "times " + scheme +" " +str->quoted(names));
}

editscheme(ctxt: ref Draw->Context, scheme: string, chanout: chan of string)
{
	(top, titlechan) := tkclient->toplevel(ctxt, "", "Operating Times", tkclient->Appl);
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");
	
	sync := chan of int;
	
	tkcmds(top, edittimescr);
	(schemedata, e) := common->readfile(adminpath + "/times/" + scheme);
	if (e != 0) {
		chanout <-= sys->sprint("alert Failed to open scheme: %r");
		return;
	}
	tkcmd(top, ".f.t insert 1.0 {"+schemedata+"}");
	tkcmd(top, ".f.e insert 0 {"+scheme+"}");

	new := 0;
	newscheme := "";
	filename := "";
	dialogpid := -1;

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);
main:
	for (;;) alt {
	inp := <- butchan =>
		if (dialogpid != -1) {
			if (inp == "closedialog") {
				tkcmd(top, "raise .; focus .");
				dialogpid = -1;
			}
			else
				continue;
		}
		(nil, lst) := sys->tokenize(inp, " \t\n");
		case hd lst {
		"new" =>
			tkcmd(top, ".f.e delete 0 end");
			tkcmd(top, ".f.t delete 1.0 end");
			new = 1;
			tkcmd(top, ".f.bdel configure -state disabled");
		"cancel" =>
			return;
		"delete" =>
			(topdialog, titlec) := tkclient->toplevel(ctxt, "", "Confirm", tkclient->Popup);
			spawn common->dialog(top, topdialog, titlec, butchan,
				("     Ok     ", "reallydelete") :: (" Cancel ", nil) :: nil, 
			"Do you really want to delete the scheme '"+scheme+"'?", sync);
			dialogpid = <-sync;
		"ok" =>

			newscheme = tkcmd(top, ".f.e get");
			filename = adminpath + "/times/" + newscheme;
			
			# Test to see if name already exists	
			if (new || newscheme != scheme) {
				(err, nil) := sys->stat(filename);
				if (err == 0) {
					tkcmd(top, "send butchan alert The scheme name '"+
						newscheme+"' is already in use");
					continue main;
				}
			}
			
			# See if we need to replace the file
			if (!new && newscheme != scheme) {
				(topdialog, titlec) := tkclient->toplevel(ctxt, "", "Confirm", tkclient->Popup);
				spawn common->dialog(top, topdialog, titlec, butchan,
					(" Create new ", "create normal") ::
					("   Replace   ", "create replace") ::
					("   Cancel   ", nil) :: nil, 
					"The scheme name has changed, do you wish to create"+
					"\na new scheme or replace '"+scheme+"'?", sync);
				dialogpid = <-sync;
			}
			else
				tkcmd(top, "send butchan create normal");
		"create" =>
			fd := sys->create(filename, sys->OWRITE, 8r666);
			if (fd == nil || sys->fprint(fd, "%s", tkcmd(top, ".f.t get 1.0 end")) < 0)
				tkcmd(top, "send butchan alert "+
					sys->sprint("Could not save scheme '%s': %r", newscheme));
			else if (hd tl lst == "replace")
				tkcmd(top, "send butchan reallydelete");
			else
				break main;

		"reallydelete" =>				
			if (sys->remove(adminpath + "/times/" + scheme) == -1)
				tkcmd(top, "send butchan "+
					sys->sprint("alert Could not remove scheme '%s': %r",
					scheme));
			else
				break main;
			
		"alert" =>
			(topdialog, titlec) := tkclient->toplevel(ctxt, "", "Confirm", tkclient->Popup);
			spawn common->dialog(top, topdialog, titlec, butchan, ("  Ok  ", nil) :: nil,
				common->list2string(tl lst), sync);
				dialogpid = <-sync;

		
		}
		tkcmd(top, "update");

	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-titlechan =>
		if (s == "exit")
			break main;
		tkclient->wmctl(top, s);
	}

	if (dialogpid != -1)
		common->kill(dialogpid);

	chanout <-= "readtimeschemes";

}

SortName.cmp(a1, a2: ref SortName, nil: int): int
{
	if (a1.name > a2.name)
		return GT;
	return LT;
}

SortName.getindex(a: array of ref SortName, name: string): int
{
	if (len a == 0)
		return -1;
	p0 := 0;
	p1 := len a - 1;
	for (;;) {
		i := (p0 + p1) / 2;
		if (a[i].name < name)
			p0 = i + 1;
		else if (a[i].name > name)
			p1 = i - 1;
		else if (a[i].name == name)
			return a[i].index;
		if (p0 > p1)
			return -1;
	}
	return -1;
}
