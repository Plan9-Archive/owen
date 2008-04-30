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
include "sh.m";
	sh: Sh;
include "./pathreader.m";
	reader: PathReader;
include "./browser.m";
	browser: Browser;
	Browse, File, Parameter: import browser;
include "readdir.m";
	readdir: Readdir;
include "arg.m";

JobMonitor: module {
	init: fn (ctxt: ref Draw->Context, argv: list of string);
	readpath: fn (file: File): (array of ref sys->Dir, int);
};

SCHED2LOCAL: con 0;
LOCAL2SCHED: con 1;

CP: con "{cp $* >[2] /dev/null}";
RM: con "{rm $* >[2] /dev/null}";
MV: con "{mv $* >[2] /dev/null}";

display: ref Draw->Display;
schedaddr := "";
schedpath := "/n/remote";
noauth := 0;
font: con " -font /fonts/charon/plain.normal.font";
fontb: con " -font /fonts/charon/bold.normal.font";
selectedfiles: list of (string, int) = nil;
labelid := 0;
contents := 0;
recurse := 1;
move := 0;
copiedids: list of int = nil;

selectedid := -1;
sourcedest := SCHED2LOCAL;
selcol, offcol: string;

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
	sh = load Sh Sh->PATH;
	if (sh == nil)
		badmod(Sh->PATH);
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

	arg->init(argv);
	arg->setusage("schedcopy [-A]");
	while ((opt := arg->opt()) != 0) {
		case opt {
		'A' =>
			noauth = 1;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	arg = nil;
	if (len argv == 1)
		schedaddr = hd argv;
	else {
		schedaddr = getschedaddr("/grid/master/schedaddr");
		if (schedaddr == nil)
			schedaddr = getschedaddr("/grid/slave/schedaddr");
		if (schedaddr == nil || len schedaddr < 5)
			error("cannot find scheduler address", 1);
		(nil, slist) := sys->tokenize(schedaddr, "!");
		if (len slist == 1)
			schedaddr = hd slist;
		else
			schedaddr = hd tl slist;
		schedaddr = "tcp!"+schedaddr+"!1234";
	}		

	sys->pctl(sys->NEWPGRP | Sys->FORKNS, nil);
	mounted := 0;
	for (; noauth < 2; noauth++) {
		mounted = mountscheduler();
		if (mounted)
			break;
	}
	if (!mounted)
		error("cannot mount scheduler: "+schedaddr, 1);

	if (ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	spawn filewin(ctxt, "Scheduler Copy");

}

mountscheduler(): int
{
	argv := schedaddr :: schedpath :: nil;
	if(noauth)
		argv = "-A" :: argv;

	if(sh->run(nil, "{mount $* >[2] /dev/null}" :: argv) == nil) {
		fd := sys->open(schedpath+"/nodename", sys->OWRITE);
		if (fd != nil)
			sys->fprint(fd, "SchedCopy");
		return 1;
	}
	return 0;
}

badmod(path: string)
{
	sys->print("Jobmonitor: failed to load: %s\n",path);
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
		sys->print("SchedCopy: TK Error: %s - '%s'\n",e,cmd);
	return e;
}

error(s: string, fail: int)
{
	sys->fprint(sys->fildes(2), "Jobmonitor: Error: %s\n",s);
	if (fail)
		raise "fail:error";
}

makescreen(top: ref Tk->Toplevel, schedrootpane, localrootpane: string)
{
	tkcmds(top, fileselectscr);
	mainscr := array[] of {
		"frame .f -bg green",
		"grid "+schedrootpane+" -in .f -row 0 -column 0 -sticky nsew",
		"grid "+localrootpane+" -in .fdest -row 0 -column 0 -sticky nsew",
		"grid .fselect -in .f -row 1 -column 0 -sticky nsew",
		"grid rowconfigure .f 0 -weight 2",
		"grid rowconfigure .f 1 -weight 1",
		"grid columnconfigure .f 0 -weight 1",
#		"grid columnconfigure .f 1 -weight 1",
#		"pack "+schedrootpane+" -in .f -fill both -expand 1 -side top",
#		"pack "+localrootpane+" -in .f -fill both -expand 1 -side top",
		"bind .Wm_t <Button-1> +{focus .Wm_t}",
		"bind .Wm_t.title <Button-1> +{focus .Wm_t}",
		"focus .Wm_t",
	};
	tkcmds(top, mainscr);
}

fileselectscr := array[] of {
	"frame .fselect",
	"frame .ffiles1 -relief sunken -borderwidth 1",
	"frame .ffiles -relief raised -borderwidth 1",
	"label .ffiles1.l -text {Selected Files}"+fontb,
	"grid .ffiles1.l -row 0 -column 0 -sticky nw -padx 2 -pady 2",
	"grid .ffiles -in .ffiles1 -row 1 -column 0 -sticky nsew",
	"grid rowconfigure .ffiles1 1 -weight 1",
	"grid columnconfigure .ffiles1 0 -weight 1",
	"scrollbar .ffiles.sx -orient horizontal -command {.ffiles.c xview}",
	"scrollbar .ffiles.sy -command {.ffiles.c yview}",
	"canvas .ffiles.c -width 20 -height 20 -yscrollcommand {.ffiles.sy set} -xscrollcommand {.ffiles.sx set}",
	"button .ffiles.bgoto -text {Goto} -takefocus 0 -command {send butchan goto} -height 14"+font,
	"button .ffiles.bdel -text {Delete} -takefocus 0 -command {send butchan delete} -height 14"+font,
	"grid .ffiles.sy -row 0 -column 0 -rowspan 2 -sticky ns",
	"grid .ffiles.sx -row 1 -column 1 -sticky sew",
	"grid .ffiles.c -row 0 -column 1 -columnspan 3 -sticky nsew",
	"grid .ffiles.bgoto -row 1 -column 2",
	"grid .ffiles.bdel -row 1 -column 3",
	"grid rowconfigure .ffiles 0 -weight 1",
	"grid columnconfigure .ffiles 1 -weight 1",
	"frame .fselfiles",
	".ffiles.c create window 0 0 -window .fselfiles -anchor nw",


	"frame .fopts1 -relief sunken -borderwidth 1",
	"frame .fopts -relief raised -borderwidth 1",
	"label .fopts1.l -text {Options}"+fontb,
	"grid .fopts1.l -row 0 -column 0 -sticky nw -padx 2 -pady 2",
	"grid .fopts -in .fopts1 -row 1 -column 0 -sticky nsew",
	"grid rowconfigure .fopts1 1 -weight 1",
	"grid columnconfigure .fopts1 0 -weight 1",
	"button .fopts.bclear -text {Clear copied files} -takefocus 0 "+
		"-command {send butchan clearcopied}"+font,
	"checkbutton .fopts.cbmove -text {Move instead of copy} -takefocus 0 "+
		"-command {send butchan setmove} -variable move"+font,
	"checkbutton .fopts.cbc -text {Dir contents only} -takefocus 0 "+
		"-command {send butchan setcontents} -variable contents"+font,
	"checkbutton .fopts.cbr -text {Recurse into subdirs} -takefocus 0 "+
		"-state disabled -variable subdirs"+font,
	"text .fopts.tlog -height 10 -width 10 -bg white -state disabled -wrap none "+
		"-xscrollcommand {.fopts.sx set} -yscrollcommand {.fopts.sy set}"+font,
	"scrollbar .fopts.sy -command {.fopts.tlog yview}",
	"scrollbar .fopts.sx -command {.fopts.tlog xview} -orient horizontal",

	"grid .fopts.cbmove -row 0 -column 0 -columnspan 2 -pady 2 -sticky w",
	"grid .fopts.cbc -row 1 -column 0 -columnspan 2 -sticky w",
	"grid .fopts.cbr -row 2 -column 0 -columnspan 2 -sticky w",
	"grid .fopts.bclear -row 3 -column 0 -columnspan 2",
	"grid .fopts.sy -row 5 -column 0 -rowspan 2 -sticky ns",
	"grid .fopts.sx -row 6 -column 1 -sticky ew",
	"grid .fopts.tlog -row 5 -column 1 -sticky nsew",
	"grid rowconfigure .fopts 4 -minsize 10",
	"grid rowconfigure .fopts 5 -weight 1",
	"grid columnconfigure .fopts 1 -weight 1",

	"frame .fdest1 -relief sunken -borderwidth 1",
	"frame .fdest -relief raised -borderwidth 1",
	"label .fdest1.l -text {Destination}"+fontb,
	"grid .fdest1.l -row 0 -column 0 -sticky nw -padx 2 -pady 2",
	"grid .fdest -in .fdest1 -row 1 -column 0 -sticky nsew",
	"grid rowconfigure .fdest1 1 -weight 1",
	"grid columnconfigure .fdest1 0 -weight 1",
	"grid rowconfigure .fdest 0 -weight 1",
	"grid columnconfigure .fdest 0 -weight 1",

	"frame .faction1 -relief sunken -borderwidth 1",
	"frame .faction -relief raised -borderwidth 1",
	"grid .faction -in .faction1 -row 1 -column 0 -sticky nsew",
	"grid rowconfigure .faction1 1 -weight 1",
	"grid columnconfigure .faction1 0 -weight 1",
	"button .faction.bcopy -text {Copy} -width 56 -takefocus 0 -bg #33FF33 "+
		"-activebackground #55FF55 -height 30 -command {send butchan go!}"+font,
	"choicebutton .faction.cbsd -values {{Scheduler to Local Machine} {Local Machine to Scheduler}} -takefocus 0 -variable sourcedest -command {send butchan sourcedest}"+font,
	"label .faction.lstatus -text {Status: ready} -anchor w -width 0"+font,

	"grid .faction.cbsd -row 4 -column 0 -pady 5",
	"grid .faction.bcopy -row 5 -column 0 -pady 5",
	"grid .faction.lstatus -row 6 -column 0 -sticky ew",
	"grid columnconfigure .faction 0 -weight 1",

	"grid .ffiles1 -in .fselect -row 0 -column 0 -rowspan 2 -sticky nsew",
	"grid .fopts1 -in .fselect -row 0 -column 2 -sticky nsew",
	"grid .fdest1 -in .fselect -row 0 -column 1 -rowspan 2 -sticky nsew",
	"grid .faction1 -in .fselect -row 1 -column 2 -sticky nsew",
	"grid rowconfigure .fselect 0 -weight 1",
	"grid columnconfigure .fselect 0 -weight 2",
	"grid columnconfigure .fselect 1 -weight 3",
	"grid columnconfigure .fselect 2 -weight 1",
};

rootpaths, rootlabels: array of string;

filewin(ctxt: ref Draw->Context, title: string)
{
	rootpaths = array[] of {
		"S"+schedpath + "/grid/master/",
		"L/",
	};
	rootlabels = array[] of {
		"Scheduler",
		"Local FS",
	};

	(top, titlebar) := tkclient->toplevel(ctxt,"", title, tkclient->Appl);
	sourcechan := chan of string;
	tk->namechan(top, sourcechan, "sourcechan");
	brs := Browse.new(top, "sourcechan", rootpaths[sourcedest],
			rootlabels[sourcedest], 2, reader);

	destchan := chan of string;
	tk->namechan(top, destchan, "destchan");
	brd := Browse.new(top, "destchan", rootpaths[1-sourcedest], 
			rootlabels[1-sourcedest], 1, reader);

	for (j := 0; j < 2; j++) {
		brs.addopened(File (rootpaths[j], nil), 1);
		brd.addopened(File (rootpaths[j], nil), 1);
	}

	butchan := chan of string;
	tk->namechan(top, butchan, "butchan");

	makescreen(top, brs.rootpane, brd.rootpane);
	
	tkcmd(top, "pack .f -fill both -expand 1; pack propagate . 0");
	tkcmd(top, ". configure -width 800 -height 700");
	tkcmd(top, "variable subdirs "+string recurse);
	tkcmd(top, "variable move "+string move);
	tkcmd(top, "variable contents "+string contents);
	tkcmd(top, "variable sourcedest "+string sourcedest);
	brs.resize();
	tkcmd(top, "update");
	
	tkclient->onscreen(top, "exact");
	tkclient->startinput(top, "kbd"::"ptr"::nil);

	selcol = " -bg #5555FF";
	offcol = " -bg "+tkcmd(top, ".fselect cget -bg");

	for (;;) {
		alt {
		s := <-top.ctxt.kbd =>
			tk->keyboard(top, s);
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		inp := <-butchan =>
			(nil, lst) := sys->tokenize(inp, " \n\t");
			case hd lst {
				"clearcopied" =>
					for (; copiedids != nil; copiedids = tl copiedids)
						delfile(top, hd copiedids);
				"setcontents" =>
					contents = int tkcmd(top, "variable contents");
					(nil, slvs) := sys->tokenize(tkcmd(top, "pack slaves .fselfiles"), "\t\n ");
					for (; slvs != nil; slvs = tl slvs) {
						text := tkcmd(top, hd slvs+" cget -text");
						if (contents && text[len text - 1] == '/')
							text += "*";
						else if (!contents && text[len text - 1] == '*')
							text = text[:len text - 1];
						tkcmd(top, hd slvs+" configure -text {"+text+"}");
					}
					if (contents)
						tkcmd(top, ".fopts.cbr configure -state normal");
					else
						tkcmd(top, ".fopts.cbr configure -state disabled");

				"sourcedest" =>
					tmp := int tkcmd(top, "variable sourcedest");
					if (tmp == sourcedest)
						break;

					if (len selectedfiles > 0) {
						setstatus(top, "Remove selected files first");
						tkcmd(top, "variable sourcedest "+string sourcedest);
						break;
					}

					sourcedest = tmp;
					brs.newroot(rootpaths[sourcedest], rootlabels[sourcedest]);
					brd.newroot(rootpaths[1-sourcedest], rootlabels[1-sourcedest]);
					brs.refresh();
					brs.gotopath(File(rootpaths[sourcedest], nil), 1);
					
				"go!" =>
					if (len selectedfiles == 0) {
						setstatus(top, "No files selected!");
						break;
					}
					destpath := brd.getselected(0).path;
					if (destpath == nil) {
						setstatus(top, "No destination selected!");
						break;
					}

					tkcmd(top, ".fopts.tlog delete 1.0 end");
					tkcmd(top, ".fopts.tlog insert end {Log\n\n}");

					move = int tkcmd(top, "variable move");
					recurse = int tkcmd(top, "variable subdirs");
					destpath = destpath[1:];
					nfailed := 0;
					copiedids = nil;
					for (tmp := selectedfiles; tmp != nil; tmp = tl tmp) {
						(filename, id) := hd tmp;
						filename = filename[1:];
						filelist := filename :: nil;
						if (filename[len filename - 1] == '/' && contents)
							filelist = path2files(filename, recurse);

						nfailed += copyfiles(top, filelist, destpath, id);
					}
					donemsg := "Complete";
					if (nfailed > 0)
						donemsg += " ("+string nfailed+" failed)";
					setstatus(top, donemsg);
					tkcmd(top, ".fopts.tlog insert end {\n"+donemsg+"\n}");
				"setmove" =>
					move = int tkcmd(top, "variable move");
					if (move)
						tkcmd(top, ".faction.bcopy configure -text {Move}");
					else
						tkcmd(top, ".faction.bcopy configure -text {Copy}");
				"select" =>
					id := int hd tl lst;
					if (selectedid == id) {
						tkcmd(top, ".fselfiles.l"+string selectedid+" configure "+offcol);
						selectedid = -1;
						break;
					}
					if (selectedid != -1)
						tkcmd(top, ".fselfiles.l"+string selectedid+" configure "+offcol);
					tkcmd(top, ".fselfiles.l"+string id+" configure "+selcol);
					selectedid = id;
				"goto" =>
					if (selectedid == -1)
						break;
					for (tmp := selectedfiles; tmp != nil; tmp = tl tmp) {
						if ((hd tmp).t1 == selectedid) {
							brs.gotoselectfile(File ((hd tmp).t0, nil));
							break;
						}
					}
				"delete" =>
					if (selectedid == -1)
						break;
					delfile(top, selectedid);
			}

			tkcmd(top, "update");
		inp := <-sourcechan =>
			(nil, lst) := sys->tokenize(inp, " \n\t");
			case hd lst {
				"double1pane1" =>
					tkpath := hd tl lst;
					f := brs.getpath(tkpath);
					addfile(top, f.path);
				* =>
					brs.defaultaction(lst, nil);
			}
			tkcmd(top, "update");
		inp := <-destchan =>
			(nil, lst) := sys->tokenize(inp, " \n\t");
			case hd lst {
				"double1pane1" =>
					tkpath := hd tl lst;
					f := brd.getpath(tkpath);
					addfile(top, f.path);
				* =>
					brd.defaultaction(lst, nil);
			}
			tkcmd(top, "update");
		titlectl := <-top.ctxt.ctl or
		titlectl = <-top.wreq or
		titlectl = <-titlebar =>
			if (titlectl == "exit")
				return;
			if (titlectl == "ok") {
				sfile := brs.getselected(1).path;
				if (sfile == nil)
					sfile = brs.getselected(0).path;
				if (sfile != nil) {
					#loadchan <-= actionstr + " " + sfile;
					return;
				}
			}
			e := tkclient->wmctl(top, titlectl);
			if (e == nil && titlectl[0] == '!') {
				brs.resize();
				tkcmd(top, "update");
			}
		}
	}
	
}

readpath(file: File): (array of ref sys->Dir, int)
{
	path := file.path[1:];
	(dirs, nil) := readdir->init(path, readdir->NAME | readdir->COMPACT);
	dirs2 := array[len dirs] of ref sys->Dir;
	n := 0;
	for (i := 0; i < len dirs; i++) {
		if ((file.path[0] == 'L' && sourcedest == SCHED2LOCAL) ||
			(file.path[0] == 'S' && sourcedest == LOCAL2SCHED)) {
			if (dirs[i].mode & sys->DMDIR)
				dirs2[n++] = dirs[i];
		}
		else
			dirs2[n++] = dirs[i];
	}
	return (dirs2[:n], 0);
}

getschedaddr(filename: string): string
{
	fd := bufio->open(filename, bufio->OREAD);
	if (fd == nil)
		return nil;
	s := fd.gets('\n');
	(nil, lst) := sys->tokenize(s, "\r\n\t ");
	if (len lst > 0)
		return hd lst;
	return nil;
}

addfile(top: ref Tk->Toplevel, filename: string)
{
	for (tmp := selectedfiles; tmp != nil; tmp = tl tmp) {
		if ((hd tmp).t0 == filename)
			return;
	}
	text := filename[len rootpaths[sourcedest] - 1:];
	if (text[len text - 1] == '/' && contents)
		text += "*";
	tkcmd(top, "label .fselfiles.l"+string labelid+" -text {"+text+"}"+font);
	tkcmd(top, "bind .fselfiles.l"+string labelid+" <Button-1> {send butchan select "+string labelid+"}");
	
	tkcmd(top, "pack .fselfiles.l"+string labelid+" -side top -anchor nw");
	tkcmd(top, ".ffiles.c configure -scrollregion {0 0 "+
		tkcmd(top, ".fselfiles cget -width") + " " + tkcmd(top, ".fselfiles cget -height")+"}");
	tkcmd(top, "update");
	selectedfiles = (filename, labelid++) :: selectedfiles;
}

delfile(top: ref Tk->Toplevel, id: int)
{
	if (selectedid == id) {
		selectedid = -1;
		lasttime := 0;
		(nil, lst) := sys->tokenize(tkcmd(top, "pack slaves .fselfiles"), "\t\n ");
		for (; lst != nil; lst = tl lst) {
			nextid := int (hd lst)[len ".fselfiles.l":];
			if (nextid == id) {
				lasttime = 1;
				continue;
			}
			selectedid = nextid;
			if (lasttime)
				break;
		}
		if (selectedid != -1)
			tkcmd(top, ".fselfiles.l"+string selectedid+" configure "+selcol);
	}
	
	tkcmd(top, "destroy .fselfiles.l"+string id);
	tmp: list of (string, int) = nil;

	for (; selectedfiles != nil; selectedfiles = tl selectedfiles) {
		if ((hd selectedfiles).t1 != id)
			tmp = hd selectedfiles :: tmp;
	}
	selectedfiles = tmp;	
	tkcmd(top, ".ffiles.c configure -scrollregion {0 0 "+
		tkcmd(top, ".fselfiles cget -width") + " " + tkcmd(top, ".fselfiles cget -height")+"}");
}

setstatus(top: ref Tk->Toplevel, msg: string)
{
	tkcmd(top, ".faction.lstatus configure -text {Status: "+msg+"}");
}

copyfiles(top: ref Tk->Toplevel, filelist: list of string, destpath: string, id: int): int
{
	nfailed := 0;
	scmd := "Copying ";
	if (move)
		scmd = "Moving ";

	for (; filelist != nil; filelist = tl filelist) {
		filename := hd filelist;	
		cmd := destpath :: nil;
		needdelete := 0;
		if (filename[len filename - 1] == '/') {
			if (contents && !recurse)
				cmd = CP :: filename :: cmd;
			else
				cmd = CP :: "-r" :: filename :: cmd;
			needdelete = move;
		}
		else {
			if (move)
				cmd = MV :: filename :: cmd;
			else
				cmd = CP :: filename :: cmd;
		}
		statmsg := scmd+filename[len rootpaths[sourcedest] - 2:];
		setstatus(top, statmsg);
		tkcmd(top, "update");
	
		tkcmd(top, ".fopts.tlog insert end {"+statmsg+"}");

#		errmsg := printlist(cmd);
		errmsg := sh->run(nil, cmd);
		if (errmsg == nil) {
			if (needdelete)			
				errmsg = sh->run(nil, getrmcmd(cmd));
#				errmsg = printlist(getrmcmd(cmd));
		}

		if (errmsg == nil)
			tkcmd(top, ".fopts.tlog insert end { (ok)\n}");
		else {
			tkcmd(top, sys->sprint(".fopts.tlog insert end { (failed)\n\t%r\n}"));
			nfailed++;
		}
		tkcmd(top, "update");
	}
	if (nfailed == 0) {
		tkcmd(top, ".fselfiles.l"+string id+" configure -fg #00AA00");
		copiedids = id :: copiedids;
	}
	else
		tkcmd(top, ".fselfiles.l"+string id+" configure -fg #FF3333");

	return nfailed;
}

getrmcmd(cpcmd: list of string): list of string
{	
	tmp: list of string = nil;
	for (cpcmd = tl cpcmd; tl cpcmd != nil; cpcmd = tl cpcmd)
		tmp = hd cpcmd :: tmp;

	rmcmd: list of string = nil;
	for (; tmp != nil; tmp = tl tmp)
		rmcmd = hd tmp :: rmcmd;

	return RM :: rmcmd;
}

path2files(path: string, incdirs: int): list of string
{
	files: list of string = nil;
	(dirs, nil) := readdir->init(path, readdir->COMPACT);
	for (i := 0; i < len dirs; i++) {
		if (dirs[i].mode & sys->DMDIR) {
			if (incdirs)
				files = path + dirs[i].name + "/" :: files;
		}
		else
			files = path + dirs[i].name :: files;
	}
	return files;
}

printlist(lst: list of string): string
{
	s := "";
	for (; lst != nil; lst = tl lst)
		s += hd lst + " ";
	sys->print("\t%s\n", s);
	return nil;
}