implement JobMonitor;

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
include "./pathreader.m";
	reader: PathReader;
include "./browser.m";
	browser: Browser;
	Browse, File, Parameter: import browser;
include "readdir.m";
	readdir: Readdir;
include "common.m";
	common: Common;
include "arg.m";

JobMonitor: module {
	init: fn (ctxt: ref Draw->Context, argv: list of string);
	readpath: fn (file: File): (array of ref sys->Dir, int);
};

C: ref Context;

pOFF, pON, pONOPT: con iota;

LT: con Common->LT;
EQ: con Common->EQ;
GT: con Common->GT;


jJOBNO, jSTATUS, jQPOS: con iota;

jNAME, jCMD, jPRE: con iota;
INT, STRING, PATH: con iota;
NILJOBSTATUS: con JobStatus (-1, -1, nil, nil, nil, 0, 0);

JOBS, NSORTS: con iota;

VJjobno, VJargv, VJstatus, VJprereq: con iota;
jobsfmtspec := array[] of {
	VJjobno => Fmtspec("id", nil),
	VJargv => Fmtspec("argv", nil),
	VJstatus => Fmtspec("status", nil),
	VJprereq => Fmtspec("prereq", nil),
};

TOTAL, COMPLETE, WAITING, RUNNING, FAILED, TASKTIME, NSTATS: con iota;
monitorfmtspec := array[] of {
	TOTAL => Fmtspec("total", nil),
	COMPLETE => Fmtspec("complete", nil),
	RUNNING => Fmtspec("running", nil),
	FAILED => Fmtspec("failed", nil),
	TASKTIME => Fmtspec("totaltime", nil),
};

jobfmt: Fmtfile;
monitorfmt: Fmtfile;

font: con Common->font;
fontb: con Common->fontb;
nobg: con Common->nobg;
adminpath: con Common->adminpath; 


jobconfigpath: list of string;
display: ref Draw->Display;
schedaddr := "";
schedrootaddr := "";
schedrootpath := "";
packages: array of string;
jobviewpref := 0;
autowait := 10;

JobStatus: adt {
	jobno, qpos: int;
	args, status: string;
	taskstats: array of int;
	starttime, selected: int;
	cmp: fn (a1, a2: ref JobStatus, sortkey: int): int;
};

JobConfig: adt {
	name, cmd, prereq: string;
	prereqmode: int;
	preargs: array of JobArg;
	cmdargs: array of JobArg;
};

JobArg: adt {
	atype: int;
	desc: string;
	opt: int;
	argid, path, lastpath: string;
	exts: list of string;
	min, max: int;
};

Context: adt {
	ajs: array of ref JobStatus;
	lastsortmode: array of int;
	invsortmode: array of int;
	selectjobi: int;
	selectjobname: int;
	completedjobs: list of int;
	jobview: int;
	aminsize: array of array of int;
	updatechan: chan of array of int;
	readersync: chan of int;
	readerpid, jobsver: int;
	jobstag, jobbindtag, jobselecttag: string;
	jobconfig: array of ref JobConfig;
	new: fn (): ref Context;
};

jobctlicons := array[] of {
	"refresh",
	"go",
	"stop",
	"del",
	"pup",
	"pdown",
};

jobcol := array[] of {
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

mainscr := array[] of {
	"frame .f",
	"frame .fjob -relief raised",
	"pack .f -fill both -expand 1",
};

jobrowminsize := array[] of {1, 6, 7, 8, 9, 10, 11};

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

ctlscr := array[] of {
	"frame .fctl1 -borderwidth 1 -relief sunken",
	"frame .fctl -borderwidth 1 -relief raised",
	"frame .fctl.fb",
	"frame .fctl.fb2",
	"frame .fctl.fctl",
	"menu .mnew"+font,

	"menubutton .fctl.fb.bjmenu -menu .mnew -text {New} -borderwidth 2 -relief raised "+font,
#	"button .fctl.fb.brefresh -command {send butchan refresh} -text {Refresh} -takefocus 0 "+font,
	"grid .fctl.fb.bjmenu -row 0 -column 0 -sticky wns",
#	"grid .fctl.fb.brefresh -row 0 -column 1 -sticky wns",

	"grid .fctl.fb -row 0 -column 0 -padx 10 -pady 5 -sticky nw",
	"pack .fctl -in .fctl1 -fill x",
};

jobdatascr := array[] of {
	"frame .fjobdata1 -borderwidth 1 -relief sunken",
	"frame .fjobdata -borderwidth 1 -relief raised",
	"label .fjobdata.ljobinfo -text {Job Information} "+fontb,

	"label .fjobdata.lfinished -text {Completed:} "+font,
	"label .fjobdata.lprocessing -text {Processing:} "+font,
	"label .fjobdata.lwaiting -text {Remaining:} "+font,
	"label .fjobdata.lfailed -text {Failed:} "+font,
	"label .fjobdata.ltotal -text {Tasks:} "+font,
	"label .fjobdata.lelapsed -text {Elapsed:} "+font,
	"label .fjobdata.lpredicted -text {Predicted:} "+font,
	"label .fjobdata.ltelapsed -text { } -anchor w "+font,
	"label .fjobdata.ltpredicted -text { } -anchor w "+font,
	"panel .fjobdata.p0",
	"panel .fjobdata.p1",
	"panel .fjobdata.p2",
	"panel .fjobdata.p3",
	"label .fjobdata.lt -font /fonts/charon/plain.small.font -text {0} -anchor w",
	"label .fjobdata.ln0 -font /fonts/charon/plain.small.font -text {0 (0%)} -anchor w",
	"label .fjobdata.ln1 -font /fonts/charon/plain.small.font -text {0 (0%)} -anchor w",
	"label .fjobdata.ln2 -font /fonts/charon/plain.small.font -text {0 (0%)} -anchor w",
	"label .fjobdata.ln3 -font /fonts/charon/plain.small.font -text {0 (0%)} -anchor w",
	"frame .fjobdata.fb",
	"button .fjobdata.fb.bview -command {send butchan tasksview} -image nos -takefocus 0",

	"frame .fjobdata.farg",
	"label .fjobdata.farg.ldesc -text {Description} "+font,
	"scrollbar .fjobdata.farg.sb -command {.fjobdata.farg.t yview}",
	"text .fjobdata.farg.t -yscrollcommand {.fjobdata.farg.sb set} -wrap word" +
		" -height 50 -width 218 -borderwidth 1 -state disabled "+font,
	"canvas .fjobdata.farg.c -height 52 -width 220 -borderwidth 0",
	"grid .fjobdata.farg.ldesc -column 0 -row 0 -columnspan 2 -sticky w",
	"grid .fjobdata.farg.sb -column 0 -row 1 -sticky nsw",
	"grid .fjobdata.farg.c -column 1 -row 1 -sticky w",
	".fjobdata.farg.c create window 0 0 -window .fjobdata.farg.t -anchor nw",
	
	"grid .fjobdata.ljobinfo -column 0 -row 0 -columnspan 2 -sticky w",
	"grid .fjobdata.farg -column 0 -row 1 -columnspan 2 -sticky w",
	"grid .fjobdata.ltotal -column 0 -row 4 -sticky w",
	"grid .fjobdata.lfinished -column 0 -row 5 -sticky w",
	"grid .fjobdata.lt -column 1 -row 4 -sticky ew",
	"grid .fjobdata.p0 -column 1 -row 5 -padx 2 -sticky ew",
	"grid .fjobdata.p1 -column 1 -row 6 -padx 2 -sticky ew",
	"grid .fjobdata.ln2 -column 1 -row 7 -sticky ew",
	"grid .fjobdata.ln3 -column 1 -row 8 -sticky ew",
	"grid .fjobdata.lprocessing -column 0 -row 7 -sticky w",
	"grid .fjobdata.lwaiting -column 0 -row 6 -sticky w",
	"grid .fjobdata.lfailed -column 0 -row 8 -sticky w",

	"grid .fjobdata.lelapsed -column 0 -row 10 -sticky w",
	"grid .fjobdata.lpredicted -column 0 -row 11 -sticky w",
	"grid .fjobdata.ltelapsed -column 1 -row 10 -sticky w",
	"grid .fjobdata.ltpredicted -column 1 -row 11 -sticky w",

	"grid .fjobdata.fb -column 0 -row 9 -sticky e -columnspan 2",
	"grid .fjobdata.fb.bview -column 2 -row 0 -sticky ens",

	"grid .fjobdata -in .fjobdata1",
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
	browser = load Browser Browser->PATH;
	if (browser == nil)
		badmod(Browser->PATH);
	browser->init();
	reader = load PathReader "$self";
	if (reader == nil)
		sys->print("cannot load reader!\n");
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmod(Arg->PATH);
	common = load Common Common->PATH;
	if (common == nil)
		badmod(Common->PATH);

	jobfmt = Fmtfile.new(jobsfmtspec);
	monitorfmt = Fmtfile.new(monitorfmtspec);

	jobconfig: list of ref JobConfig = nil;
	jobconfigpath = "/grid/master" :: nil;
	noauth := 0;
	keyfile: string;
	arg->init(argv);
	arg->setusage("jobmonitor [-A] [-a nsecs] [-j newjobpath] [-k keyfile] scheduleraddress [schedulerrootaddress]");
	while ((opt := arg->opt()) != 0) {
		case opt {
		'A' =>
			noauth = 1;
		'a' =>
			autowait = int arg->earg();
			if (autowait < 1)
				arg->usage();
		'j' =>
			jobconfigpath = arg->earg() :: jobconfigpath;
		'k' =>
			keyfile = arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if (argv == nil || len argv > 2)
		arg->usage();
	schedaddr = hd argv;
	if (tl argv != nil) {
		schedrootaddr = hd tl argv;
		schedrootpath = "/n/local";
	}
	arg = nil;
	sys->pctl(sys->NEWPGRP | Sys->FORKNS, nil);
	
	if (ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	common->init(display, schedrootpath, schedrootaddr, schedaddr, noauth, keyfile);
	if (schedrootpath != nil)
		common->mountschedroot();

	for (; jobconfigpath != nil; jobconfigpath = tl jobconfigpath) {
		path := schedrootpath + hd jobconfigpath;
		(dirs, nil) := readdir->init(path, readdir->NAME | readdir->COMPACT);
		for (i := 0; i < len dirs; i++) {
			if (len dirs[i].name > 4 && dirs[i].name[len dirs[i].name - 4:] == ".new") {
				jc := getjobconfig(path+"/"+dirs[i].name);
				if (jc != nil)
					jobconfig = jc :: jobconfig;
				else
					sys->fprint(sys->fildes(2), "Invalid file format: %s/%s\n", path, dirs[i].name);
			}
		}
	}			
	jobconfig = ref JobConfig("Generic", "", "", pONOPT,
				array[] of { JobArg (STRING, "Prerequisite", 1, nil, nil, nil, nil, 0, 0) },
				array[] of {
					JobArg (STRING, "Description", 1, nil, nil, nil, nil, 0, 0),
					JobArg (STRING, "Command", 0, "", "", "", nil, 0, 0)
				}) :: jobconfig;

	spawn window(ctxt, jobconfig);
}

badmod(path: string)
{
	sys->print("Jobmonitor: failed to load: %s\n",path);
	exit;
}

loadicons(top: ref Tk->Toplevel)
{
	tkcmd(top, "image create bitmap bars -file @/icons/monitor/bars.bit");
	tkcmd(top, "image create bitmap nos -file @/icons/monitor/nos.bit");
	for (i := 0; i < len jobctlicons; i++)
		tkcmd(top, "image create bitmap "+jobctlicons[i]+" -file @/icons/monitor/"+
			jobctlicons[i]+".bit -maskfile @/icons/monitor/"+jobctlicons[i]+"mask.bit");
}

window(ctxt: ref Draw->Context, jobconfig: list of ref JobConfig)
{
 	i: int;
	C = Context.new();
	C.jobconfig = common->list2array(jobconfig);
	jobconfig = nil;
	(top, title) := tkclient->toplevel(ctxt, "", "Job Monitor", tkclient->Appl);
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");

	drawscreen(top, C);

	barimg := common->getbarimg();
	drawfont := Font.open(display, "/fonts/charon/plain.small.font");
	if (drawfont == nil)
 		error(sys->sprint("could not open /fonts/charon/plain.small.font: %r"), 0);
	bar := array[4] of ref Image;
	col := array[len bar] of ref Image;
	for (i = 0; i < len bar; i++) {
		bar[i] = display.newimage(((0,0),(104,Common->BARH)), Draw->RGB24, 0, Draw->Black);
		bar[i].draw(barimg.r, barimg, nil, barimg.r.min);
		col[i] = common->getcol(i);
		tk->putimage(top, ".fjobdata.p"+string i, bar[i], nil);
	}
	powerimg := display.newimage(((0,0),(104,Common->BARH)), Draw->RGB24, 0, Draw->Black);
	powerimg.draw(barimg.r, barimg, nil, barimg.r.min);

	timer := chan of int;
	spawn common->secondtimer(timer);

	tkcmd(top, "send butchan refresh");
	tkcmd(top, "pack propagate . 0");
	tkcmd(top, ". configure -width 263 -height 550");
	resize(top);
	firsttime := 1;
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tcount := 0;
	connected := 1;
	topdialog: ref Tk->Toplevel = nil;
	dialogpid := -1;
	retrykillchan := chan[1] of int;

	spawn common->tkhandler(top, butchan, title);
	main: for (;;) alt {
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
			# sys->print("inp: %s\n", inp);
			(nil, lst) := sys->tokenize(inp, " \t\n");
			case hd lst {
				"alert" =>
					titlec: chan of string;
					sync := chan of int;
					(topdialog, titlec) = tkclient->toplevel(ctxt,
							"", "Alert", tkclient->Popup);
					spawn common->dialog(top, topdialog, titlec, butchan,
							("  Ok  ", nil) :: nil, common->list2string(tl lst), sync);
					dialogpid = <-sync;
				"newjob" =>
					spawn newjob(C, ctxt, top, int hd tl lst, butchan);
				"jobbutton" =>
					if (C.selectjobi == -1)
						break;
					jobno := C.ajs[C.selectjobi].jobno;
					
					case hd tl lst {
						"refresh" =>
							refresh(top, C, firsttime, 0);
							firsttime = 0;
						"del" =>
							dtitle, msg: string;
							butlist: list of (string, string);
							if (C.ajs[C.selectjobi].taskstats != nil &&
								iscomplete(C, C.ajs[C.selectjobi].jobno)) {
								dtitle = "Confirm";
								butlist = ("Ok", "jobbutton reallydel "+string jobno) ::
									("Cancel", nil) :: nil;
								msg = "Remove completed job: "+string jobno+"?";
							}
							else {
								dtitle = "Warning!";
								butlist = ("Delete", "jobbutton reallydel "+string jobno) ::
									("Cancel", nil) :: nil;
								msg = "Warning: Job "+string jobno+" is still running!";
							}
							titlec: chan of string;
							sync := chan of int;
							(topdialog, titlec) = tkclient->toplevel(ctxt,
									"", dtitle, tkclient->Popup);
							spawn common->dialog(top, topdialog, titlec, butchan,
									butlist, msg, sync);
							dialogpid = <-sync;
						"reallydel" =>
							common->jobctlwrite(int hd tl tl lst, "delete");
							C.selectjobi++;
							if (C.selectjobi >= len C.ajs)
								C.selectjobi -= 2;
							if (C.selectjobi < 0)
								C.selectjobname = -1;
							else
								C.selectjobname = C.ajs[C.selectjobi].jobno;
							tkcmd(top, "send butchan refreshjobs");
						* =>
							# If job is complete then the following 
							# actions should have no effect

							if (iscomplete(C, jobno))
								break;

							case hd tl lst {
							"go" =>
								common->jobctlwrite(jobno, "start");
								tkcmd(top, "send butchan refreshjobs");
							"stop" =>
								titlec: chan of string;
								sync := chan of int;
								(topdialog, titlec) = tkclient->toplevel(ctxt,
										"", "Alert", tkclient->Popup);
								spawn common->dialog(top, topdialog, titlec, butchan,
										("Just Stop", "jobbutton reallystop 0") ::
										("Stop & Teardown", "jobbutton reallystop 1") :: nil, 
										"Teardown current tasks for job "+
										string jobno+"?", sync);
								dialogpid = <-sync;
							"reallystop" =>
								teardown := int hd tl tl lst;
								common->jobctlwrite(jobno, "stop");
								if (teardown)
									common->jobctlwrite(jobno, "teardown");
								tkcmd(top, "send butchan refreshjobs");
	
							"pmax" =>
								common->jobctlwrite(jobno, "priority high");
								tkcmd(top, "send butchan refreshjobs");
							"pmin" =>
								common->jobctlwrite(jobno, "priority low");
								tkcmd(top, "send butchan refreshjobs");
							"pup" =>
								changepriority(C, C.selectjobi, -1);
								tkcmd(top, "send butchan refreshjobs");
							"pdown" =>
								changepriority(C, C.selectjobi, +2);
								tkcmd(top, "send butchan refreshjobs");
							}
					}

				"reconnect" =>
					(topdialog, nil) = tkclient->toplevel(ctxt, "", "", tkclient->Plain);
					rsync := chan of int;
					spawn common->reconnect(top, topdialog, butchan, rsync, retrykillchan);
					dialogpid = <-rsync;
					connected = 0;
				"reconnected" =>
					connected = 1;
					selectfirst := 0;
					C.completedjobs = nil; # reset this as we can't guarantee that that
										# the job no.s are the same since remount
					if (C.selectjobname == -1)
						selectfirst = 1;
					refresh(top, C, selectfirst, 0);
				"refreshjobs" =>
					refreshjobs(top, C);
				"refresh" =>
					refresh(top, C, firsttime, 0);
					firsttime = 0;
				"select" =>
					if (hd tl lst == "job") {
						if (len C.ajs == 0)
							break;
						id := int hd tl tl lst;
						if (hd tl tl lst == "YPoint2") {
							id = int hd tl tl tl lst/17;
							if (id < 0 || id >= len C.ajs)
								break;
						}
						else break;
						selectjob(top, C, id);
					}

				"sort" =>
					stype := int hd tl lst;
					sortmode := int hd tl tl lst;
					if (sortmode == C.lastsortmode[stype])
						C.invsortmode[stype] = ++C.invsortmode[stype] % 2;
					else
						C.invsortmode[stype] = 0;
					C.lastsortmode[stype] = sortmode;
					if (stype == JOBS) {
						common->sort(C.ajs, sortmode, C.invsortmode[stype]);
						updatejobswin(top, C);
					}
				"tasksview" =>
					if (C.jobview != jobviewpref)
						break;
					C.jobview = ++C.jobview % 2;
					jobviewpref = C.jobview;
					showbars(top, C);
					tkcmd(top, "update");
				"nojob" =>
					updatejobdata2(top, nil, drawfont, barimg, bar, col);
					updatejobdata(top, nil);
					updatetime(top, nil,0);
				"resize" =>
					resize(top);
				"exit" =>
					break main;
			}
			tkcmd(top, "update");
		n := <-C.readersync =>
			if (n < 0) {
				if (C.selectjobi != -1) {
					addcompletedjob(C, C.ajs[C.selectjobi].jobno);
					updatetime(top, C.ajs[C.selectjobi],1);
				}
			}
			else
				common->kill(C.readerpid);
			C.readerpid = -1;
		au := <-C.updatechan =>
			C.ajs[C.selectjobi].taskstats = au;
			updatejobdata2(top, C.ajs[C.selectjobi], drawfont, barimg, bar, col);
			updatetime(top, C.ajs[C.selectjobi], iscomplete(C, C.ajs[C.selectjobi].jobno));
			tkcmd(top, "update");
		<-timer =>
			if (topdialog != nil) {
				common->centrewin(top, topdialog);
				tkcmd(topdialog, "focus .");
			}
			tcount++;
			if (tcount % autowait == 0) {
				refresh(top, C, firsttime, 1);
				tcount = 0;
				firsttime = 0;
			}
			if (!connected)
				break;

			if (C.selectjobi == -1 || len C.ajs <= C.selectjobi)
				break;
			if (C.ajs[C.selectjobi].taskstats == nil || iscomplete(C, C.ajs[C.selectjobi].jobno))
				break;
			updatetime(top, C.ajs[C.selectjobi], 0);
	}
	if (dialogpid != -1)
		common->killg(dialogpid);
	common->killg(sys->pctl(0, nil));
}


selectjob(top: ref Tk->Toplevel, C: ref Context, id: int)
{
	if (id >= len C.ajs)
		return;
	if (id != -1 && C.selectjobname == C.ajs[id].jobno)
		return;

	if (C.readerpid != -1)
		common->kill(C.readerpid);

	if (C.jobselecttag != nil)
		tkcmd(top, ".fjob.fdisp.c delete "+C.jobselecttag);
	C.jobselecttag = nil;
	tk->cmd(top, "destroy .fselectjob");
	if (id != -1) {
		w := string common->max(int tkcmd(top, ".fjobs cget -width"),
						int tkcmd(top, ".fjob.fdisp.c cget -width"));
		tkcmd(top, "frame .fselectjob -bg blue*0.25 -height 17 -width "+w);
		C.jobselecttag = tkcmd(top, ".fjob.fdisp.c create window 0 "+
			string (17*id)+" -window .fselectjob -anchor nw");
		tkcmd(top, ".fjob.fdisp.c see 0 "+string (17 * id)+" 1 " +
			string ((17 * (id + 1)) - 1));
		C.selectjobname = C.ajs[id].jobno;
		spawn jobreader(C);
		C.readerpid = <-C.readersync;
		updatejobdata(top, C.ajs[id]);
	}
	else {
		C.selectjobname = -1;
		C.readerpid = -1;
		tkcmd(top, "send butchan nojob");
	}
	C.selectjobi = id;
}

showbars(top: ref Tk->Toplevel, C: ref Context)
{
	for (i := 0; i < 2; i++) {
		tk->cmd(top, "grid forget .fjobdata.p"+string i);
		tk->cmd(top, "grid forget .fjobdata.ln"+string i);
	}
	if (C.jobview == 1) {
		for (i = 0; i < 2; i++)
			tkcmd(top, "grid .fjobdata.ln"+string i+
				" -sticky w -column 1 -row "+string (i+5));
		tkcmd(top, ".fjobdata.fb.bview configure -image bars");
	}
	else {
		for (i = 0; i < 2; i++)
			tkcmd(top, "grid .fjobdata.p"+string i+
				" -sticky w -padx 2 -column 1 -row "+string (i+5));
		tkcmd(top, ".fjobdata.fb.bview configure -image nos");
	}
}

selist2s(se: list of ref Sexp): string
{
	if(se == nil)
		return nil;
	s := sys->sprint("%q", (hd se).astext());
	for(se = tl se; se != nil; se = tl se)
		s += sys->sprint(" %q", (hd se).astext());
	return s;
}
		
updatetime(top: ref Tk->Toplevel, js: ref JobStatus, completed: int)
{
	if (js == nil) {
		tkcmd(top, ".fjobdata.ltpredicted configure -text {}");
		tkcmd(top, ".fjobdata.ltelapsed configure -text {}");
		tkcmd(top, "update");
		return;
	}
	predicted := "unknown";
	elapsed := "unknown";
	ts := js.taskstats;
	if (completed) {
		predicted = "finished";
		duration := getduration(js.jobno);
		if (duration != -1)
			elapsed = common->formattime(duration);
	}
	else if (ts[TOTAL] == -1) {
		if (js.starttime != -1)
			elapsed = common->formattime(daytime->now() - js.starttime);
	}
	else {
		if (ts[COMPLETE] > 0 && ts[RUNNING] > 0 && ts[TASKTIME] > 0)
			predicted = common->formattime(int (( real (ts[TOTAL] - ts[COMPLETE]) * 
							(real ts[TASKTIME])/real ts[COMPLETE]) /
							real ts[RUNNING]));
		if (js.starttime != -1)
			elapsed = common->formattime(daytime->now() - js.starttime);
	}
	tkcmd(top, ".fjobdata.ltpredicted configure -text {"+predicted+"}");
	tkcmd(top, ".fjobdata.ltelapsed configure -text {"+elapsed+"}");
	tkcmd(top, "update");
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
		sys->print("Job Monitor: TK Error: %s - '%s'\n",e,cmd);
	return e;
}

Context.new(): ref Context
{
	lastsort := array[NSORTS] of { * => 0};
	invsort := array[NSORTS] of { * => 0};
	lastsort[JOBS] = jQPOS;
	aminsize: array of array of int;
	dummy: array of int = nil;
	aminsize = array[NSORTS] of { * => dummy };
	return ref Context(nil, lastsort, invsort, -1, -1, nil,
				0, aminsize, chan of array of int, chan of int,
				-1, -1,
				nil, nil, nil, nil);
}

JobStatus.cmp(a1, a2: ref JobStatus, sortkey: int): int
{
	if (sortkey == jSTATUS) {
		if (a1.status < a2.status)
			return LT;
		if (a1.status > a2.status)
			return GT;
		return common->sortint(a1.qpos, a2.qpos);
	}
	else if (sortkey == jQPOS){
		r1 := (a1.status == "running")<<1;
		r2 := a2.status == "running";
		case r1 | r2 {
		2r11 =>
			return common->sortint(a1.qpos, a2.qpos);
		2r10 =>
			return r2;
		2r01 =>
			return r1;
		2r00 =>
			return common->sortint(a2.jobno, a1.jobno);
		}
	}
	return common->sortint(a1.jobno, a2.jobno);
}


readjobstatus(C: ref Context, auto: int): int
{

	if (auto) {
		(n, dir) := sys->stat(adminpath+"/jobs");
		if (n == -1) {
			error(sys->sprint("could not stat %s/jobs: %r",adminpath), 0);
			C.jobsver = 1;
			return 0;
		}
		if (dir.qid.vers == C.jobsver)
			return 0;
	}
	
	# C.jobsver = dir.qid.vers;
	iobuf := jobfmt.open(adminpath+"/jobs");
	if (iobuf == nil) {
		error(sys->sprint("could not open %s/jobs: %r",adminpath), 0);
		return 0;
	}
	l: list of ref JobStatus = nil;
	for (;;) {
		(v, err) := jobfmt.read(iobuf);
		if(v == nil){
			if(err != nil)
				error("error reading jobs file: "+err, 0);
			break;
		}
		jobno := int v[VJjobno].text();
		starttime := -1;
		duration := getduration(jobno);
		desc := getdescription(jobno);
		if (desc != nil) {
			if (desc[len desc -1] != '\n')
				desc[len desc] = '\n';
			desc += "\nParameters:\n";
		}
	
		if (duration != -1)
			starttime = daytime->now() - duration;
		desc += selist2s(v[VJargv].val.els());
		prereq := v[VJprereq].val;
		if(prereq.els() != nil)
			desc += "\nPrerequisite:\n"+selist2s(prereq.els());
		js := ref JobStatus (jobno, -1, desc, v[VJstatus].val.astext(), nil, starttime, 0);
		l = js :: l;
	}
	C.ajs = array[len l] of ref JobStatus;
	i := len l - 1;
	for (; l != nil; l = tl l) {
		C.ajs[i] = hd l;
		C.ajs[i].qpos = i;
		i--;
	}
	cleancompletedjobs(C);
	return 1;
}

getduration(jobno: int): int
{
	duration := -1;
	iobuf := bufio->open(adminpath+"/"+string jobno+"/duration", bufio->OREAD);
	if (iobuf != nil) {
		s := iobuf.gets('\n');
		if (s != nil)
			duration = int (big s/ big 1000);	
	}
	else
		error(sys->sprint("cannot read %s/%d/duration: %r\n",adminpath,jobno), 0);
	return duration;
}

getdescription(jobno: int): string
{
	iobuf := bufio->open(adminpath+"/"+string jobno+"/description", bufio->OREAD);
	if (iobuf != nil)
		return iobuf.gets('\n');
	return nil;
}

updatejobdata(top: ref Tk->Toplevel, js: ref JobStatus)
{
	if (js == nil)
		tkcmd(top, ".fjobdata.farg.t delete 1.0 end");
	else if (js.args != tkcmd(top, ".fjobdata.farg.t get 1.0 end")) {
		tkcmd(top, ".fjobdata.farg.t delete 1.0 end");
		tkcmd(top, ".fjobdata.farg.t insert 1.0 {"+js.args+"}");
	}
}

updatejobswin(top: ref Tk->Toplevel, C: ref Context): int
{
	if (C.jobstag != nil)
		tkcmd(top, ".fjob.fdisp.c delete "+C.jobstag);

	tk->cmd(top, "destroy .fjobs");
	tkcmd(top, "frame .fjobs "+nobg);
	C.jobstag = tkcmd(top, ".fjob.fdisp.c create window 0 0 -window .fjobs -anchor nw");

	showselected := -1;

	common->setminsize(top, ".fjobs", C.aminsize[JOBS]);
	row := 0;
	for (i := 0; i < len C.ajs; i++) {
		if (C.ajs[i].jobno == C.selectjobname)
			showselected = i;
		si := string i;
		sr := string row;
		tkcmd(top, "frame .fjobs.fcol"+si+" -width 10 -height 10 -borderwidth 1"+
			" -relief raised -bg "+ jobcol[C.ajs[i].jobno % len jobcol]);
		tkcmd(top, "label .fjobs.lname"+si+" -text {"+string C.ajs[i].jobno+"}"+nobg+font);
		tkcmd(top, "label .fjobs.lstatus"+si+" -text {"+C.ajs[i].status+"} -fg red"+nobg+font);
		tkcmd(top, "label .fjobs.lqpos"+si+" -text {"+string C.ajs[i].qpos+"}"+nobg+font);
		tkcmd(top, "grid .fjobs.fcol"+si+" -row "+sr+" -column 0 -padx 2 -pady 2");
		tkcmd(top, "grid .fjobs.lname"+si+" -row "+sr+" -column 1 -sticky w");
		tkcmd(top, "grid .fjobs.lstatus"+si+" -row "+sr+" -column 2 -sticky w -padx 2");
		tkcmd(top, "grid .fjobs.lqpos"+si+" -row "+sr+" -column 3 -sticky w -padx 2");
		row++;
	}
	tkcmd(top, "frame .fjobs.fl -bg white -width 0 -height 0");
	tkcmd(top, "grid .fjobs.fl -row 0 -column 4");
	w := string common->max(int tkcmd(top, ".fjobs cget -width"),
					int tkcmd(top, ".fjob.fdisp.c cget -width"));
	h := tkcmd(top, ".fjobs cget -height");
	tkcmd(top, ".fjob.fdisp.c configure -scrollregion {0 0 "+ w + " " + h + "}");

	if (C.jobbindtag == nil) {
		tkcmd(top, "frame .fjobbind -bg #00000000 -width "+w+" -height "+h);
		tkcmd(top, "bind .fjobbind <Button-1> {send butchan select job YPoint2 %y}");
		C.jobbindtag = tkcmd(top, ".fjob.fdisp.c create window 0 0"+
						" -window .fjobbind -anchor nw");
	}
	else
		tkcmd(top, ".fjobbind configure -width "+w+" -height "+h);
	tkcmd(top, ".fjob.fdisp.c raise "+C.jobbindtag+" "+C.jobstag);
	if (showselected != -1) {
		C.selectjobname = -1;
		selectjob(top, C, showselected);
		return 1;
	}
	else {
		if (C.jobselecttag != nil)
			tkcmd(top, ".fjob.fdisp.c delete "+C.jobselecttag);	
		C.jobselecttag = nil;
		tk->cmd(top, "destroy .fselectjob");
		selectjob(top, C, -1);
		return 0;
	}
}

jobreader(C: ref Context)
{
	path := adminpath+"/"+string C.selectjobname+"/monitor";
	iobuf := monitorfmt.open(path);
	if (iobuf == nil) {
		error(sys->sprint("could not open %s: %r", path), 0);
		C.readersync <-= -1;
		return;
	}
	C.readersync <-= sys->pctl(0, nil);
	for (;;) {
		(v, err) := monitorfmt.read(iobuf);
		if(v == nil){
			if(err != nil)
				error("error reading monitor file: "+err, 0);
			C.readersync <-= -2;
			return;
		}
		taskstats := array[NSTATS] of int;
		for(i := 0; i < NSTATS; i++)
			taskstats[i] = int v[i].val.astext();
		C.updatechan <-= taskstats;
	}
}

updatejobdata2(top: ref Tk->Toplevel, js: ref JobStatus, font: ref Font, barimg: ref Image, bar, col: array of ref Image)
{
	if (js == nil) {
		js = ref NILJOBSTATUS;
		js.taskstats = array[1 + FAILED] of { * => 0 };
	}
	C.jobview = jobviewpref;
	if (js.taskstats[TOTAL] == -1) {
		tkcmd(top, ".fjobdata.lt configure -text {unknown}");
		if (C.jobview == 0)
			C.jobview = 1;
	}
	else
		tkcmd(top, ".fjobdata.lt configure -text {"+string js.taskstats[TOTAL]+"}");
	showbars(top, C);
	js.taskstats[WAITING] = js.taskstats[TOTAL] - js.taskstats[COMPLETE];
	if (js.taskstats[WAITING] < 0)
		js.taskstats[WAITING] = 0;

	k := 0;
	for (i := COMPLETE; i <= FAILED; i++) {
		percent: int;
		if (js.taskstats[TOTAL] < 1)
			percent = 0;
		else
			percent = (js.taskstats[i] * 100) / js.taskstats[TOTAL];
		bar[k].draw(barimg.r, barimg, nil, barimg.r.min);
		tkcmd(top, sys->sprint(".fjobdata.ln%d configure -text {%s (%d%%)}",
			k, common->formatno(js.taskstats[i]), percent));
		if (i == FAILED) {
			fgcol := "black";
			if (js.taskstats[FAILED] > 0)
				fgcol = "red";
			tkcmd(top, ".fjobdata.ln"+string k+" configure -fg "+fgcol);
		}
		
		bar[k].draw(((2,2),(2+percent,Common->BARH-2)), col[k], nil, (0,0));
		if (font != nil)
			bar[k].text((41,2), display.black, (0,0), font, string percent+"%");
		tkcmd(top, ".fjobdata.p"+string k+" dirty");
		k++;
	}
	tkcmd(top, "update");
}

resize(top: ref Tk->Toplevel)
{
	height := tkcmd(top, ". cget -actheight");
	width := int tkcmd(top, ". cget -actwidth");
	if (width != 263) {
		tkcmd(top, ". configure -width 263 -height "+height);
		tkcmd(top, "update");
	}
}

drawscreen(top: ref Tk->Toplevel, C: ref Context)
{
	i: int;
	loadicons(top);
	tkcmds(top, mainscr);
	tkcmds(top, ctlscr);
	for (i = 0; i < len C.jobconfig; i++)
		tkcmd(top, ".mnew add command -command {send butchan newjob "+
			string i+"} -label {"+C.jobconfig[i].name+" Job}");
	col := 2;
	for (i = 0; i < len jobctlicons; i++) {
		sc := string col;
#		tkcmd(top, "button .fctl.fctl.b"+sc+" -command {send butchan jobbutton "+
#			jobctlicons[i]+"} -takefocus 0 -image "+jobctlicons[i]);
#		tkcmd(top, "grid .fctl.fctl.b"+sc+" -sticky w -row 0 -column "+sc);
		tkcmd(top, "button .fctl.fb.b"+sc+" -command {send butchan jobbutton "+
			jobctlicons[i]+"} -takefocus 0 -image "+jobctlicons[i]);
		tkcmd(top, "grid .fctl.fb.b"+sc+" -sticky w -row 0 -column "+sc);
		col++;
	}
	tkcmd(top, "grid columnconfigure .fctl.fctl "+string (col - 1)+" -minsize 40");
	tkcmds(top, jobdatascr);
	tkcmd(top, "grid columnconfigure .fjobdata 1 -minsize "+
		string(int tkcmd(top, ".fjobdata cget -actwidth") -
			int tkcmd(top, ".fjobdata.lprocessing cget -actwidth")));

	common->makescrollbox(top, JOBS, ".fjob.fdisp", 220, 50,  "-bg white -borderwidth 2",
					(nil, nil) :: ("Job No.", nil) :: ("Status", nil) :: ("Queue", nil) :: nil);
	tkcmd(top, "grid rowconfigure .fjob.fdisp 1 -weight 1");

	headings: list of (string, string) = nil;
	for (pv := len packages - 1; pv >= 0; pv--) {
		name := packages[pv] + " Version";
		name[0] += 'A' - 'a';
		headings = (name, nil) :: headings;
	}
	headings = ("Online","pcicon") :: ("Name", nil) :: ("IP Address", nil) :: ("Cpu", nil) ::
			 ("Mem", nil) :: ("Tasks", nil) :: ("Jobs", nil) :: ("Last Connected", nil) :: headings;

	tkcmd(top, "grid .fjob.fdisp -column 1 -row 1 -sticky senw -pady 5");
	tkcmd(top, "grid rowconfigure .fjob 1 -weight 1");

	tkcmd(top, "frame .f.fleft");
	tkcmd(top, "pack .fctl1 -in .f.fleft -side top -fill x");
	tkcmd(top, ".fjob configure");
	tkcmd(top, "pack .fjob -in .f.fleft -side top -fill y -expand 1");
	
	tkcmd(top, "pack .f.fleft -padx 10 -pady 10 -fill y -expand 0 -side left");

	common->minsize(top, ".fjobdata");

	tkcmd(top, "grid .fjobdata1 -in .fjob -row 3 -column 0 -columnspan 2 -sticky w");
	#tkcmd(top, "grid rowconfigure .fjob 2 -minsize 5");

	showbars(top, C);
	for (i = 0; i < len jobrowminsize; i++)
		tkcmd(top, "grid rowconfigure .fjobdata "+string jobrowminsize[i]+" -minsize 20");

#	wt := int tkcmd(top, ". cget -width");
#	ht := int tkcmd(top, ". cget -height");
#	w := int tkcmd(top, ".f cget -width");
#	h = int tkcmd(top, ".f cget -height");
#	diffx = wt - w;
#	diffy = ht - h;
}

refreshjobs(top: ref Tk->Toplevel, C: ref Context)
{
	(n, nil) := sys->stat(adminpath);
	if (n == -1) {
		# sys->print("stat %s failed, reconnecting: %r\n", adminpath);
		tkcmd(top, "send butchan reconnect");
		return;
	}
	readjobs := readjobstatus(C, 0);
	if (readjobs) {
		common->sort(C.ajs, C.lastsortmode[JOBS], C.invsortmode[JOBS]);
		updatejobswin(top, C);
		C.aminsize[JOBS] = common->doheading(top, ".fjobs", ".fjob.fdisp", nil, 1);
	}	
}

refresh(top: ref Tk->Toplevel, C: ref Context, firsttime, auto: int)
{
	(n, nil) := sys->stat(adminpath);
	if (n == -1) {
		# sys->print("stat2 %s failed, reconnecting: %r\n", adminpath);
		tkcmd(top, "send butchan reconnect");
		return;
	}

	if (readjobstatus(C, auto)) {
		common->sort(C.ajs, C.lastsortmode[JOBS], C.invsortmode[JOBS]);
		if (firsttime) {
			for (i := 0; i < len C.ajs; i++) {
				if (C.ajs[i].qpos == 0)
					C.selectjobname = C.ajs[i].jobno;
			}
		}
		updatejobswin(top, C);
		C.aminsize[JOBS] = common->doheading(top, ".fjobs", ".fjob.fdisp", nil, 1);
	}	
}

error(s: string, fail: int)
{
	sys->fprint(sys->fildes(2), "Jobmonitor: Error: %s\n",s);
	if (fail)
		raise "fail:error";
}

changepriority(C: ref Context, id, mv: int)
{
	s := "";
	max := len C.ajs - 1;
	qpos := C.ajs[id].qpos + mv;
	if (qpos <= 0)
		s = "high";
	else if (qpos >= max)
		s = "low";
	else {
		for (i := 0; i < len C.ajs; i++) {
			if (C.ajs[i].qpos == qpos-1) {
				s = string C.ajs[i].jobno;
				break;
			}
		}
	}
	if (s != nil)
		common->jobctlwrite(C.ajs[id].jobno, "priority "+s);	
}


getjobconfig(path: string): ref JobConfig
{
	iobuf := bufio->open(path, bufio->OREAD);
	if (iobuf == nil)
		return nil;
	cmdargs := JobArg (STRING, "Description", 1, nil, nil, nil, nil, 0, 0) :: nil;
	preargs: list of JobArg = nil;
	prereqmode := pOFF;
	mode := -1;

	s := array[3] of string;
	s[1] = "";
	s[2] = "";
	s[0] = delnewline(iobuf.gets('\n'));
	if (s[0] == nil)
		return nil;

	test := "jobconfig:";
	if (len s[0] <= len test || str->tolower(s[0][:len test]) != test)
		return nil;
	(nil, lnm) := sys->tokenize(s[0][len test:], " \t");
	if (lnm == nil)
		return nil;
	s[0] = hd lnm;
	for (;;) {
		a := iobuf.gets('\n');
		if (a == nil)
			break;
		lst := str->unquoted(a);
		if (lst == nil)
			continue;
		if (hd lst == "pre:") {
			mode = jPRE;
			prereqmode = pON;
			s[jPRE] = common->list2string(tl lst);
			continue;
		}
		if (hd lst == "preopt:") {
			mode = jPRE;
			prereqmode = pONOPT;
			s[jPRE] = common->list2string(tl lst);
			continue;
		}
		else if (hd lst == "cmd:") {
			mode = jCMD;
			s[jCMD] = common->list2string(tl lst);
			continue;
		}
		if (mode == -1)
			continue;
		if (len lst < 4)
			continue;
		arg := JobArg(STRING, hd tl lst, int hd tl tl lst, hd tl tl tl lst, "/", nil, nil, 0, 0);
		case hd lst {
			"int" => arg.atype = INT;
			"string" => arg.atype = STRING;
			"path" => arg.atype = PATH;
			* => continue;
		}
		lst = tl tl tl tl lst;
		if (arg.atype == INT && len lst >= 2) {
			arg.min = int hd lst;
			arg.max = int hd tl lst;
		}
		else if (arg.atype == PATH && len lst >= 1) {
			arg.path = hd lst;
			if (arg.path == nil || arg.path[len arg.path - 1] != '/')
				arg.path[len arg.path] = '/';
			arg.exts = tl lst;
		}
		arg.lastpath = arg.path;
		if (mode == jCMD)
			cmdargs = arg :: cmdargs;
		else
			preargs = arg :: preargs;
	}
	if (cmdargs == nil || s[jCMD] == nil)
		return nil;
	
	return ref JobConfig (s[jNAME], s[jCMD], s[jPRE], prereqmode,
			jobarglist2array(preargs), jobarglist2array(cmdargs));
}

jobarglist2array(args: list of JobArg): array of JobArg
{
	l := len args;
	jargs := array[l] of JobArg;
	for (; args != nil; args = tl args)
		jargs[--l] = hd args;
	return jargs;
}

delnewline(s: string): string
{
	if (s != nil && s[len s - 1] == '\n')
		return s[:len s - 1];
	return s;
}

makenewjobscr(top: ref Tk->Toplevel, C: ref Context, id: int)
{
	tk->cmd(top, "destroy .f");
	tkcmd(top, "image create bitmap folder -file @/icons/monitor/browse.bit" +
		" -maskfile @/icons/monitor/browsemask.bit");
	
	tkcmd(top, "frame .f; frame .f.f1; frame .f.f2");

	createArgWidgets(top, ".f.f1", C.jobconfig[id].cmdargs);
	if (C.jobconfig[id].prereqmode != pOFF) {
		# only show prereq bit if there are args to modify
		if (len C.jobconfig[id].preargs > 0) {
			tkcmd(top, "frame .f.fpre");
			if (C.jobconfig[id].prereqmode == pONOPT)
				tkcmd(top, "checkbutton .f.cbpre -variable pre -text {Prerequisite}"+fontb);
			else
				tkcmd(top, "label .f.cbpre -text {Prerequisite}"+fontb);
			createArgWidgets(top, ".f.fpre", C.jobconfig[id].preargs);
			tkcmd(top, "grid .f.cbpre -row 2 -column 0 -padx 10 -pady 10 -sticky w");
			tkcmd(top, "grid .f.fpre -row 3 -column 0 -padx 10 -pady 5 -sticky w");
			tkcmd(top, "grid rowconfigure .f.fpre 0 -minsize 40");
		}
		tkcmd(top, "variable pre 1");
	}
	else
		tkcmd(top, "variable pre 0");

	tkcmd(top, "button .f.f2.bstart -text {Start Job} -takefocus 0 -command {send butchan start}"+font);
	tkcmd(top, "button .f.f2.bcancel -text {Cancel} -takefocus 0 -command {send butchan cancel}"+font);
	tkcmd(top, "grid .f.f2.bstart .f.f2.bcancel -row 0 -padx 20");
	tkcmd(top, "grid .f.f1 -row 1 -column 0 -padx 10 -pady 10");
	tkcmd(top, "grid .f.f2 -row 4 -column 0 -padx 10 -pady 10");
	tkcmd(top, "grid rowconfigure .f.f1 0 -minsize 40");
	tkcmd(top, "pack .f; focus .; raise .");
}

createArgWidgets(top: ref Tk->Toplevel, frame: string, args: array of JobArg)
{
	for (i := 0; i < len args; i++) {
		sr := string i;
		w := 240;
		browse := 0;
		if (args[i].atype == INT)
			w = 60;
		else if (args[i].atype == PATH)
			browse = 1;

		tkcmd(top, "label "+frame+".l"+sr+" -text {"+args[i].desc+":}"+font);
		tkcmd(top, "grid "+frame+".l"+sr+" -sticky wn -row "+sr+" -column 0");
		tkcmd(top, "entry "+frame+".e"+sr+" -width "+string w+" -bg white "+font);
		tkcmd(top, "bind "+frame+".e"+sr+" <Key> {send butchan key "+frame+" "+sr+" %s}");
		if (browse) {
			tkcmd(top, "button "+frame+".b"+sr+" -takefocus 0 -image folder"+
				" -command {send butchan browse "+frame+" "+sr+"}");
			tkcmd(top, "grid "+frame+".b"+sr+" -sticky wn -row "+sr+" -column 3");
		}
		if (w == 60) {
			if (args[i].min < args[i].max) {
				tkcmd(top, "frame "+frame+".fs"+sr);
				tkcmd(top, "button "+frame+".fs"+sr+".badd -text {+} -height 15 -width 15" +
					" -command {send butchan add "+frame+" "+sr+" 1} -takefocus 0"+
					" -font /fonts/charon/plain.small.font");
				tkcmd(top, "button "+frame+".fs"+sr+".bdel -text {-} -height 15 -width 15" +
					" -command {send butchan add "+frame+" "+sr+" -1} -takefocus 0"+
					" -font /fonts/charon/plain.small.font");
				tkcmd(top, "scale "+frame+".fs"+sr+".s -orient horizontal -takefocus 0"+
					" -from "+string args[i].min + " -bigincrement 10" +
					" -to "+string args[i].max +
					" -command {send butchan set "+frame+" "+sr+"} -showvalue 0 -height 23");
				tkcmd(top, "grid "+frame+".fs"+sr+".bdel "+frame+".fs"+sr+
					".badd "+frame+".fs"+sr+".s"+" -row 0");
				tkcmd(top, "grid "+frame+".fs"+sr+" -sticky ew -row "+sr+" -column 2");
			}
			tkcmd(top, "grid "+frame+".e"+sr+" -sticky wn -row "+sr+" -column 1");
		}
		else
			tkcmd(top, "grid "+frame+".e"+sr+" -sticky wn -columnspan 2 -row "+sr+" -column 1");
		tkcmd(top, "grid rowconfigure "+frame+" "+sr+" -minsize 25");
	}
}

newjob(C: ref Context, ctxt: ref Draw->Context, oldtop: ref Tk->Toplevel, id: int, chanout: chan of string)
{
	title := "New "+C.jobconfig[id].name+" Job";
	(top, titlectl) := tkclient->toplevel(ctxt, "", title, tkclient->Hide);
	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");
	makenewjobscr(top, C, id);
	common->centrewin(oldtop, top);
	tkcmd(top, "focus .f.f1.e0; update");
	tkclient->onscreen(top, "exact");
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	for (;;) {
		alt {
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		inp := <- butchan =>
			lst := str->unquoted(inp);
			case hd lst {
				"add" =>
					w := hd tl lst + ".e" + hd tl tl lst;
					argi := int hd tl tl lst;
					val := int hd tl tl tl lst + int tkcmd(top, w+" get");
					if (val < C.jobconfig[id].cmdargs[argi].min)
						val = C.jobconfig[id].cmdargs[argi].min;
					if (val > C.jobconfig[id].cmdargs[argi].max)
						val = C.jobconfig[id].cmdargs[argi].max;
					tkcmd(top, w+" delete 0 end");
					tkcmd(top, w+" insert insert {"+string val+"}");
					tkcmd(top, hd tl lst+".fs"+hd tl tl lst+".s set "+string val+"; update");
				"set" =>
					w := hd tl lst +".e" + hd tl tl lst;
					val := int hd tl tl tl lst;
					tkcmd(top, w+" delete 0 end");
					tkcmd(top, w+" insert insert {"+string val+"}; update");
				"key" =>
					argi := int hd tl tl lst;
					key := " ";
					key[0] = int hd tl tl tl lst;
					iscmd := 1;
					ja: array of JobArg;
					if (hd tl lst == ".f.f1")
						ja = C.jobconfig[id].cmdargs;
					else {
						ja = C.jobconfig[id].preargs;
						iscmd = 0;
					}
					if (key == "\t") {
						frame := hd tl lst;			
						argi++;
						if (argi >= len ja) {
							argi = 0;
							if (!iscmd || len C.jobconfig[id].preargs == 0)
								frame = ".f.f1";
							else
								frame = ".f.fpre";
						}
						tkcmd(top, "focus "+frame+".e"+string argi+"; update");
						break;
					}
					if (ja[argi].atype == INT) {
						if ((key < "0" || key > "9") && key != "." && key != "-")
							break;
					}
					w := hd tl lst +".e"+string argi;
					if (tkcmd(top, w + " selection present") == "1")
						tkcmd(top, w + " delete sel.first sel.last");
					tkcmd(top, w + " insert insert "+tk->quote(key));
					tkcmd(top, w + " see insert; update");
				"addfile" =>
					sargi := hd tl tl lst;
					argi := int sargi;
					file := hd tl tl tl lst;
					w := hd tl lst +".e"+ sargi;
					tkcmd(top, w + " delete 0 end");
					ja: array of JobArg;
					if (hd tl lst == ".f.f1")
						ja = C.jobconfig[id].cmdargs;
					else
						ja = C.jobconfig[id].preargs;
					ja[argi].lastpath = file[:1+common->isatback(file, "/")];
					tkcmd(top, w + " insert 0 {"+file[len string id + len sargi + 3:]+"}");
					tkcmd(top, "focus "+w+"; update");
				"browse" =>
					argi := int hd tl tl lst;
					ja: array of JobArg;
					if (hd tl lst == ".f.f1")
						ja = C.jobconfig[id].cmdargs;
					else
						ja = C.jobconfig[id].preargs;

					btitle := "Select "+ja[argi].desc;
					rootpath := "/" + string id + "/"+string argi+"/";

					spawn filewin(top, ctxt, btitle, "addfile "+hd tl lst+" "+string argi,
						ja[argi].path, rootpath,
						ja[argi].lastpath, butchan);
				"cancel" =>
					return;
				"start" =>
					tkcmd(top, ".f.f2.bstart configure -state disabled");
					tkcmd(top, ".f.f2.bcancel configure -state disabled");
					tkcmd(top, "update");
					prereq := "";
					desc := tkcmd(top, ".f.f1.e0 get");
					(cmd, runit) := args2string(top, ".f.f1", C.jobconfig[id].cmdargs, 1);
					if (tkcmd(top, "variable pre") == "1" && runit) {
						
						(prereq, runit) = args2string(top, ".f.fpre",
											C.jobconfig[id].preargs, 0);
						prereq = "prereq "+C.jobconfig[id].prereq + prereq;
					}
					if (!runit)
						break;

					cmd = "load " + C.jobconfig[id].cmd + cmd;

					#sys->fprint(sys->fildes(2), "cmd: '%s'\npre: '%s'\n", cmd, prereq);
					#break;

					buf := array[sys->ATOMICIO] of byte;
					fd := sys->open(adminpath+"/clone", sys->ORDWR);
					err := 0;
					if (fd != nil) {
						i := sys->read(fd, buf, len buf);
						if (i > 0) {
							jobno := int string buf[:i];
							i = sys->fprint(fd, "%s", cmd);
							if (i > 0) {
								if (prereq != nil)
									sys->fprint(fd, "%s", prereq);
								sys->fprint(fd, "start");
								fddesc := sys->open(adminpath+"/"+
									string jobno+"/description", sys->OWRITE);
								if (fddesc != nil && desc != nil)
									sys->fprint(fddesc, "%s", desc);
								chanout <-= sys->sprint("refreshjobs");
								# chanout <-= sys->sprint("alert Job %d loaded", jobno);
								return;
							}
							else
								err = 1;
						}
						else
							err = 1;
					}
					else
						err = 1;
					if (err)
						chanout <-= sys->sprint("alert Failed to start job: %r");
					tkcmd(top, ".f.f2.bstart configure -state normal");
					tkcmd(top, ".f.f2.bcancel configure -state normal");
					tkcmd(top, "update");
			}

		s := <-top.ctxt.ctl or
		s = <-top.wreq or
		s = <-titlectl =>
			if (s == "exit")
				return;
			tkclient->wmctl(top, s);
		}
	}
}

args2string(top: ref Tk->Toplevel, frame: string, args: array of JobArg, startat: int): (string, int)
{
	focus := "";
	argstr := "";
	runit := 1;
	for (argi := startat; argi < len args; argi++) {
		si := string argi;
		val := tkcmd(top, frame+".e"+si+" get");
		if (val != nil) {
			if (args[argi].atype == PATH && val[0] != '/')
				val = args[argi].path + val;
			if (args[argi].argid != nil)
				argstr += " " + args[argi].argid;
			argstr += " "+val;
			tkcmd(top, frame+".l"+si+" configure -fg black");
		}
		else {
			if (!args[argi].opt) {
				tkcmd(top, frame+".l"+si+" configure -fg red");
				runit = 0;
				if (focus == nil)
					focus = frame+".e"+si;
			}
		}
	}
	if (!runit) {
		if (focus != nil)
			tkcmd(top, "focus "+focus);
		tkcmd(top, ".f.f2.bstart configure -state normal");
		tkcmd(top, ".f.f2.bcancel configure -state normal");
		tkcmd(top, "update");
		return (nil, 0);
	}
	return (argstr, 1);
}

makefileselectscreen(top: ref Tk->Toplevel, rootpane: string)
{
	fileselectscr := array[] of {
		"frame .f -bg green",
		"pack "+rootpane+" -in .f -fill both -expand 1",
		"bind .Wm_t <Button-1> +{focus .Wm_t}",
		"bind .Wm_t.title <Button-1> +{focus .Wm_t}",
		"focus .Wm_t",
	};
	tkcmds(top, fileselectscr);
}

filewin(oldtop: ref Tk->Toplevel, ctxt: ref Draw->Context, title, actionstr, root, rootpath, lastfilepath: string, loadchan: chan of string)
{
	(top, titlebar) := tkclient->toplevel(ctxt,"", title, tkclient->OK | tkclient->Appl);
	browsechan := chan of string;
	tk->namechan(top, browsechan, "browsechan");
	br := Browse.new(top, "browsechan", rootpath, root, 2, reader);
	br.addopened(File (rootpath, nil), 1);
	br.gotoselectfile(File (lastfilepath, nil));

	makefileselectscreen(top, br.rootpane);
	
	tkcmd(top, "pack .f -fill both -expand 1; pack propagate . 0");
	tkcmd(top, ". configure -width 450 -height 300");
	br.resize();
	tkcmd(top, "update");
	
	common->centrewin(oldtop, top);
	tkclient->onscreen(top, "exact");
	tkclient->startinput(top, "kbd"::"ptr"::nil);

	for (;;) {
		alt {
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		inp := <-browsechan =>
			(nil, lst) := sys->tokenize(inp, " \n\t");
			case hd lst {
				"double1pane1" =>
					tkpath := hd tl lst;
					f := br.getpath(tkpath);
					if (f.path != nil && f.path[len f.path - 1] == '/')
						br.defaultaction(lst, f);
					else {
						loadchan <-= actionstr + " " + f.path;
						return;
					}
				* =>
					br.defaultaction(lst, nil);
			}
			tkcmd(top, "update");
		titlectl := <-top.ctxt.ctl or
		titlectl = <-top.wreq or
		titlectl = <-titlebar =>
			if (titlectl == "exit")
				return;
			if (titlectl == "ok") {
				sfile := br.getselected(1).path;
				if (sfile == nil)
					sfile = br.getselected(0).path;
				if (sfile != nil) {
					loadchan <-= actionstr + " " + sfile;
					return;
				}
			}
			e := tkclient->wmctl(top, titlectl);
			if (e == nil && titlectl[0] == '!') {
				br.resize();
				tkcmd(top, "update");
			}
		}
	}
	
}

readpath(file: File): (array of ref sys->Dir, int)
{
	(nil, lst) := sys->tokenize(file.path, "/");
	id := int hd lst;
	argi := int hd tl lst;
	path := schedrootpath + C.jobconfig[id].cmdargs[argi].path +
			file.path[len hd lst + len hd tl lst + 3:];
	# sys->print("reading: %s\n",path);
	(dirs, nil) := readdir->init(path, readdir->NAME | readdir->COMPACT);
	dirs2 := array[len dirs] of ref sys->Dir;
	n := 0;
	for (i := 0; i < len dirs; i++) {
		tmp := C.jobconfig[id].cmdargs[argi].exts;
		if (tmp == nil || dirs[i].mode & sys->DMDIR)
			dirs2[n++] = dirs[i];
		else {
			ext := common->getext(dirs[i].name);
			for (; tmp != nil; tmp = tl tmp)
				if (ext == hd tmp) {
					dirs2[n++] = dirs[i];
					break;
			}
		}
	}
	return (dirs2[:n], 0);
}

addcompletedjob(C: ref Context, jobno: int)
{
	for (tmp := C.completedjobs; tmp != nil; tmp = tl tmp)
		if (hd tmp == jobno)
			return;
	C.completedjobs = jobno :: C.completedjobs;
}

cleancompletedjobs(C: ref Context)
{
	tmp := C.completedjobs;
	C.completedjobs = nil;
	
	for (i := 0; i < len C.ajs; i++) {		
		for (tmp2 := tmp; tmp2 != nil; tmp2 = tl tmp2) {
			if (hd tmp2 == C.ajs[i].jobno)
				C.completedjobs = C.ajs[i].jobno :: C.completedjobs;
		}
	}
}

iscomplete(C: ref Context, jobno: int): int
{
	for (tmp := C.completedjobs; tmp != nil; tmp = tl tmp)
		if (hd tmp == jobno)
			return 1;
	return 0;
}
