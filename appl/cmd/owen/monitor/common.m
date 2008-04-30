Common: module {

	PATH: con "/dis/scheduler/common.dis";

	ED: con Draw->Enddisc;
	BARH: con 14;
	MIN: con 60;
	HOUR: con MIN * 60;
	DAY: con HOUR * 24;
	WEEK: con DAY * 7;
	MONTH: con WEEK * 4;
	
	LT: con -1;
	EQ: con 0;
	GT: con 1;
	MAXBACKOFF: con 5 * MIN * 1000;
	font: con " -font /fonts/charon/plain.normal.font";
	fontb: con " -font /fonts/charon/bold.normal.font";
	nobg: con " -bg #00000000 ";
	
	schedulepath: con "/n/remote";
	adminpath: con "/n/remote/admin";

	init: fn (disp: ref Draw->Display, srootpath, srootaddr, saddr: string, hasnoauth: int, keyfile: string);
	badmod: fn (path: string);
	centrewin: fn (oldtop, top: ref Tk->Toplevel);
	ctlwrite: fn (path, msg: string): int;
	dialog: fn (oldtop, top: ref Tk->Toplevel, titlec, chanout: chan of string, butlist: list of (string, string), msg: string, sync: chan of int);
	doheading: fn (top: ref Tk->Toplevel, frame, topframe, headingframe: string, startcol: int): array of int;
	error: fn (s: string, fail: int);
	formatno: fn (n: int): string;
	getbarimg: fn (): ref Image;
	getcol: fn (i: int): ref Image;
	getext: fn (file: string): string;
	getsysname: fn (): string;
	isatback: fn (s, test: string): int;
	jobctlwrite: fn (jobid: int, msg: string): int;
	kill: fn (pid: int);
	killg: fn (pid: int);
	list2array: fn [T](lst: list of T): array of T;
	list2string: fn (l: list of string): string;
	makeheadings: fn (top: ref Tk->Toplevel, startcol, stype: int, frame: string, headings: list of (string, string));
	makescrollbox: fn (top: ref Tk->Toplevel, stype: int, frame: string, x,y: int, args: string, headings: list of (string, string));
	maparray: fn (data: array of string, lst: list of string): array of int;
	max: fn (i1, i2: int): int;
	minmax: fn (a1, a2: int): (int, int);
	min: fn (i1, i2: int): int;
	minsize: fn (top: ref Tk->Toplevel, frame: string);
	mountscheduler: fn (sync: chan of int);
	mountschedroot: fn();
	reconnect: fn (oldtop, top: ref Tk->Toplevel, chanout: chan of string, sync, killchan: chan of int);
	secondtimer: fn (sync: chan of int);
	setminsize: fn (top: ref Tk->Toplevel, frame: string, aminsize: array of int);
	sort: fn [T](a: array of T, sortkey, inv: int) for {
	T =>
		cmp: fn (a1, a2: T, sortkey: int): int;
	};
	sortint: fn (a,b: int): int;
	tkhandler: fn (top: ref Tk->Toplevel, butchan, titlechan: chan of string);
	formattime: fn (secs: int): string;
	readfile: fn (filename: string): (string, int);

	jobcol: array of string;
};