implement Scheduler;

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "string.m";
	str: String;
include "arg.m";
include "sets.m";
	sets: Sets;
	Set, A, B: import sets;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "readdir.m";
	readdir: Readdir;
include "archives.m";
	archives: Archives;
	Archive, Unarchive: import archives;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "format.m";
	format: Format;
	Fmtspec, Fmt: import Format;
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "nstyxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Eperm: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "timetable.m";
	timetable: Timetable;
	Times: import timetable;
include "taskgenerator.m";
	Started, Error, Nomore, Clientspec,
	Readreq, Writereq, Finishreq, Taskgenreq: import Taskgenerator;

# tunable constants and values
Maxreqidle: con 10;
Minmonitorrefresh: con big 500;		# ms
Maxnodefailures: con 5;				# max consecutive failures before blacklist
NoDNS: con 0;
Debugstyx := 0;
Debugmem: con 0;
Verbose := 0;
taskgenpath :=  "/dis/owen";
root := "/grid/master";

# + should log blacklisting events

# note: debugger should allow inspection of values held inside buffered channels.
# note: if a fileserver breaks inside a clunk, GC can be held up until it's killed.

# requirements:
# + execution and result recovery of multiple win32 tasks making up a gold job.
# + queuing of several outstanding jobs

# + failure modes:
#	+ abnormal scheduler termination
#	+ abnormal worker termination
#	+ network failure

# + log significant events (need resolved name and IP addr when mentioning other machines)

# + status information:
# 	+ list of jobs
# 	+ status of each job
# 	+ worker info
#		+ status (how many connected)
#		+ host name
#		+ last known IP addr
#		+ last known time it was connected
#		+ CPU speed
#		+ memory
#		+ number of tasks completed
# 	+ current job & task ids for all workers currently involved in processing

# + control interface
# 	+ start new job, specifying job params.
# 	+ stop a running or queued job.
# 	+ resume a stopped job.
# 	+ delete a running or queued job.
# 	+ set a priority on a running or queued job.
# 	+ restrict a job to a defined group of nodes
# 	+ exclude a worker (& stop task on that worker).

# + isolate task generator as a separate process.

# + dns reverse lookup

# + high priority
#	+ failed task count should mean *completely* failed
#	+ allow node deletion
#	+ deleted state for jobs
#	+ auto checkpoint
#	+ deleting a job while running crashes the system (can't reproduce)
#	+ logfile rollover
#	+ check for gold errors
#	+ need to archive/restore the global group

# - low priority
#	+ global group
#	- qid version on jobs & nodes file
#	- monitor to show last tasks run on a node
#	+ job naming + description
#	+ per-job predicates
#	- named groups
#	+ permissions/certificates

# - current issues
#	+(ish) don't give failed tasks to the same worker.

# possible issues:
# + try to avoid immediately rescheduling a failed job on the same worker.
# - dump: what happens if we dump while a job is in the middle of
#	completing, and then crash? what should happen on restore? will complete be called again?
# - should one be able to specify a restore file that's different from the name of the file
#	we're going to dump to?
# + task generator cleanup of files
# 	- move work directories for old jobs out of the way so that they're easily deleted.

Scheduler: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# filesystem looks like:
#	task
#	reconnect
#	stoptask
#	attrs
#	admin/
#		jobs
#		nodes
#		times/
#			always
#			...
#		formats
#		clone
#		n/
#			ctl
#			monitor
#			duration
#			group
#			data

Job: adt {
	id:		int;
	uniq:		string;
	argv:		list of string;
	refcount:	int;
	taskgen:	ref Taskgen;
	prereq:	Prereq;
	prereqargs: list of string;
	failed:	ref Table[ref Task];
	disconnected: ref Table[ref Task];
	running:	ref Table[ref Taskinst];
	setstatch:	chan of (int, int, int);
	getstatsch: chan of (int, chan of (int, array of int));
	starttime: big;
	lock:		chan of int;
	group:	Set;
	queued:	int;
	maxtaskuniq:	int;
	done:	int;
	deleted:	int;
	nomore:	int;
	description:	string;
	owner:	string;

	new:		fn(id: int, uniq: string, user: string): ref Job;
	getstats:	fn(j: self ref Job, version: int, flushc: chan of int): (int, array of int);
	setstat:	fn(j: self ref Job, what, v: int);
	complete:	fn(j: self ref Job, sync: chan of int);
	incref:	fn(j: self ref Job): int;
	decref:	fn(j: self ref Job);
	teardown:	fn(j: self ref Job, nongroup: int);
	idtext:	fn(j: self ref Job): string;
};

Jobqueue: adt {
	jobs:		 list of ref Job;

	add:			fn(q: self ref Jobqueue, j: ref Job);
	del:			fn(q: self ref Jobqueue, j: ref Job);
	get:			fn(q: self ref Jobqueue): ref Job;
	peek:		fn(q: self ref Jobqueue): ref Job;
	setpriority:	fn(q: self ref Jobqueue, j: ref Job, justbelow: ref Job, high: int);
	isempty:		fn(q: self ref Jobqueue): int;
	all:			fn(q: self ref Jobqueue): list of ref Job;
};

Jobctl: adt {
	job: ref Job;
	pick {
	Priority =>
		justbelow:	ref Job;
		high:			int;
	Start =>
	Stop =>
	Delete =>
	Teardown =>
		nongroup:	int;
	}
};

# a task as handed out by the taskgenerator
Task: adt {
	tgid:		string;
	id:		int;
	jobid:	int;
	jobuniq:	string;
	tries:		int;
	failed:	int;
	running:	int;
	done:	int;
	nok:		int;			# number of times this task has completed successfully.
	dumped:	int;
	laststarttime:	big;
	setstatch:	chan of (int, int, int);
	lock:		chan of int;

	setstat:	fn(t: self ref Task, what, v: int);
	incstat:	fn(t: self ref Task, what, v: int);
	idtext:	fn(t: self ref Task): string;
	about:	fn(t: self ref Task): string;
};

# a particular running instance of a task.
Taskinst: adt {
	id:		int;			# distinct for this particular instance of the task
	task:		ref Task;
	read:		chan of Readreq;
	write:	chan of Writereq;
	finish:	chan of Finishreq;
	starttime:	big;
	clientid:	string;
	node:	ref Node;		# node currently running this task
	stopped:	int;

	new:		fn(task: ref Task): ref Taskinst;
	stop:		fn(t: self ref Taskinst);
};

Taskgen: adt {
	req:		chan of ref Taskgenreq;

	new:	fn(jobuniq: string, state: string, kick: chan of int, args: list of string): (ref Taskgen, string);
	taskcount: fn(t: self ref Taskgen): int;
	state: fn(t: self ref Taskgen): string;
	opendata: fn(t: self ref Taskgen,
		user: string,
		mode: int,
		read:		chan of Readreq,
		write:	chan of Writereq,
		clunk:	chan of int): string;
	start: fn(t: self ref Taskgen,
		id: string,
		duration: 	int,
		failed:	int,
		spec: ref Clientspec,
		read:		chan of Readreq,
		write:	chan of Writereq,
		finish:	chan of Finishreq): (int, string);
	reconnect: fn(t: self ref Taskgen, id: string,
		read:		chan of Readreq,
		write:	chan of Writereq,
		finish:	chan of Finishreq): (int, string);
	complete:	fn(t: self ref Taskgen);
	quit:	fn(t: self ref Taskgen);
};

Sfid: adt {
	fid:			int;
	task:			ref Taskinst;	# Qtask
	state:		int;			# Qtask (starts with Treadtaskid)
	job:			ref Job;
	statsversion:	int;			# Qmonitor
	laststatstime:	big;			# Qmonitor: time that last stats were handed out.
	fmt:			array of Fmt;	# Qjobs, Qnodes, Qmonitor
	laststats:		string;		# Qmonitor
	read:		chan of Readreq;	# Qjobdata
	write:	chan of Writereq;	# Qjobdata
	clunk:	chan of int;		# Qjobdata
};

Nodetimes: adt {
	id:	int;
	name: string;
	t: ref Times;
	refcount: int;
	text:	string;

	get: fn(n: self ref Nodetimes, t: int): (int, int);
};

Nodeinfo: adt {
	id:		int;
	name:	string;
	ipaddr:	string;
	connected:	int;
	disconnecttime:	big;
	taskscomplete:	int;
	tasksfailed: int;
	blacklisted:	int;
	attrs:		Attrs[string];
	tasks:	list of (string, ref Task);
	times:	ref Nodetimes;

	deltask:	fn(n: self ref Nodeinfo, t: ref Task);
	delipaddr:	fn(n: self ref Nodeinfo, ip: string);
	addtask:	fn(n: self ref Nodeinfo, t: ref Task, ip: string);
};

Node: adt {
	info:		ref Nodeinfo;
	lasttask:	string;
	ipaddr:	string;
	user:		string;
	groups:	int;
	active:	chan of int;
	stoptask:		chan of string;
	getstoptask:	chan of string;
	stopbufproc:	chan of int;		# shut down buffer process between stoptask and getstoptask
};

# groups
Gadmin, Gworker, Gsubmit, Gmonitor: con 1<<iota;

Table: adt[T] {
	items:	array of list of (int, T);
	nilval:	T;

	new: fn(nslots: int, nilval: T): ref Table[T];
	add:	fn(t: self ref Table, id: int, x: T): int;
	del:	fn(t: self ref Table, id: int): int;
	find:	fn(t: self ref Table, id: int): T;
};

Strhash: adt[T] {
	items:	array of list of (string, T);
	nilval:	T;

	new: fn(nslots: int, nilval: T): ref Strhash[T];
	add:	fn(t: self ref Strhash, id: string, x: T);
	del:	fn(t: self ref Strhash, id: string);
	find:	fn(t: self ref Strhash, id: string): T;
};

# Qtask states: (Treadtaskid is actually Twritetaskid for Qreconnect)
Treadtaskid, Twritetaskid, Ttaskcomms: con iota;
Tstartstate: con Treadtaskid;

NOTIME: con big 16r8000000000000000;

QMask: con 16r1f;
QShift: con 5;

# formatted files must come first in thie list because we use
# the qid as an index into formats.
Qjobs, Qnodes, Qmonitor,
Qroot,
Qtask, Qreconnect, Qattrs, Qnodename, Qstoptask, Qadmindir,
Qjobdir, Qformats, Qgroup, Qctl, Qclone, Qtimesdir,
Qtimes,
Qlog, Qduration, Qjobctl, Qjobgroup, Qjobdescription, Qjobdata, Qjobid, Qjobnodes: con iota;

Admin: con "admin";

Incval, Setval: con iota;
Stotal, Scomplete, Srunning, Sfailed, 
Sdatain, Sdataout, Sdisconnected,		# XXX datain and dataout are going to wrap...
Sduplicate, Stotaltime,
Snumstats: con iota;

Egreg: con "chris locke'd it";

Eok, Eduplicate, Eerror, Edisconnect, Efinished: con iota;		# task end status

tmsgsend: chan of (string, ref Tmsg);

logch: chan of string;
dumpid := 1;
dumpfile: string;
adminid: string;
workerid: string;

timefd: ref Sys->FD;
starttime := big 0;

nodes:	ref Table[ref Node];			# currently connected nodes.
allnodes:	ref Strhash[ref Nodeinfo];		# all nodes that have ever connected (hashed by node name)
allnodeslock: chan of int;
maxconnid := 0;
maxnodeid := 0;
globalgroup := Sets->All;

fids := array[107] of list of ref Sfid;		# hashed by fid
srv:		ref Styxserver;
tree:		ref Tree;

Tag: adt {
	m: ref Tmsg;			# for debugging
	flushc: chan of int;
};
tags:		ref Table[ref Tag];
tagslock: chan of int;

reqpool:	list of chan of (ref Tag, ref Fid);
reqidle:	int;
reqdone: 	chan of chan of (ref Tag, ref Fid);
clunked:	chan of ref Fid;
taskmonlock:	chan of int;
kicktaskmon:	chan of int;

jobs:		ref Table[ref Job];
maxjobid := 1;
uniqid: string;
times:	ref Table[ref Nodetimes];
Always:	ref Nodetimes;
maxtimesid := 1;
timeslock: chan of int;

Statsreq: type chan of (int, chan of (int, array of int));

taskreqch: chan of (ref Node, chan of (ref Job, ref Taskinst));
taskreconnectch: chan of (ref Node, string, chan of (ref Job, ref Taskinst, string));
taskflushch: chan of chan of (ref Job, ref Taskinst);
taskendch: chan of (int, ref Job, ref Taskinst, string);
jobctlch: chan of ref Jobctl;
getjobsch: chan of chan of list of ref Job;
newnodech: chan of (string, chan of ref Nodeinfo);
dumpch: chan of chan of string;
timeschanged: chan of int;

fidlock: chan of int;
VAattr, VAval: con iota;
VJargv, VJid, VJncomplete, VJntotal, VJprereq, VJstatus, VJuniq: con iota;
VNattrs, VNblacklisted, VNdisconnecttime, VNipaddr, VNname, VNncompleted, VNnconnected, VNnfailed, VNtasks, VNtimes: con iota;
VTjobid, VTjobuniq, VTtaskid: con iota;

fmtspecs := array[] of {
Qmonitor =>
	Fmtspec(
		"monitor",
		array[] of {
		Stotal => Fmtspec("total", nil),
		Scomplete => Fmtspec("complete", nil),
		Srunning => Fmtspec("running", nil),
		Sfailed => Fmtspec("failed", nil),
		Sdatain => Fmtspec("datain", nil),
		Sdataout => Fmtspec("dataout", nil),
		Sdisconnected => Fmtspec("disconnected", nil),
		Sduplicate => Fmtspec("duplicate", nil),
		Stotaltime => Fmtspec("totaltime", nil),
		}
	),
Qjobs =>
	Fmtspec(
		"jobs",
		array[] of {
		VJuniq => Fmtspec("uniq", nil),
		VJid => Fmtspec("id", nil),
		VJstatus => Fmtspec("status", nil),
		VJncomplete => Fmtspec("ncomplete", nil),
		VJntotal => Fmtspec("ntotal", nil),
		VJargv => Fmtspec("argv", nil),
		VJprereq => Fmtspec("prereq", nil),
		}
	),
Qnodes =>
	Fmtspec(
		"nodes",
		array[] of {
		VNname => Fmtspec("name", nil),
		VNipaddr => Fmtspec("ipaddr", nil),
		VNnconnected => Fmtspec("nconnected", nil),
		VNdisconnecttime => Fmtspec("disconnecttime", nil),
		VNncompleted => Fmtspec("ncompleted", nil),
		VNnfailed => Fmtspec("nfailed", nil),
		VNblacklisted => Fmtspec("blacklisted", nil),
		VNtimes => Fmtspec("times", nil),
		VNattrs => Fmtspec("attrs",
			array[] of {
			VAattr => Fmtspec("attr", nil),
			VAval => Fmtspec("val", nil),
			}
		),
		VNtasks => Fmtspec("tasks",
			array[] of {
			VTjobuniq => Fmtspec("jobuniq", nil),
			VTjobid => Fmtspec("jobid", nil),
			VTtaskid => Fmtspec("taskid", nil),
			}
		),
		}
	),
};
formats: array of Fmt;

# archival field orderings, used by dump() and restore()
FJid, FJuniq, FJargv, FJstarttime, FJgroup, FJmaxtaskuniq, FJdone, FJtgstate, FJowner, FJprereq: con iota;
jobfmt := array[] of {
	FJid=>"id",
	FJuniq=>"uniq",
	FJargv=>"argv",
	FJstarttime=>"starttime",
	FJgroup=>"group",
	FJmaxtaskuniq=>"maxtaskuniq",
	FJdone=>"done",
	FJtgstate=>"tgstate",
	FJowner=>"owner",
	FJprereq=>"prereq",
};

FTjobid, FTtgid, FTid, FTdisconnected, FTtries, FTfailed: con iota;
taskfmt := array[] of {
	FTjobid=>"jobid",
	FTtgid=>"tgid",
	FTid=>"id",
	FTdisconnected=>"disconnected",
	FTfailed=>"failed",
	FTtries=>"tries",
};

FNid, FNattrs, FNname, FNipaddr, FNdisconnecttime,
FNtaskscomplete, FNtasksfailed, FNblacklisted, FNtimes: con iota;		
nodefmt := array[] of {
	FNid=>"id",
	FNname=>"name",
	FNipaddr=>"ipaddr",
	FNdisconnecttime=>"disconnecttime",
	FNtaskscomplete=>"taskscomplete",
	FNtasksfailed=>"tasksfailed",
	FNblacklisted=>"blacklisted",
	FNtimes=>"times",
	FNattrs=>"attrs",
};

FMid, FMname, FMtext: con iota;
timesfmt := array[] of {
	FMid=>"id",
	FMname=>"name",
	FMtext=>"text"
};

styxoutput: ref Sys->FD;
memfd: ref Sys->FD;
	
init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	# stop nastiness when we're killpgrped - make
	# sure other processes don't pick up stdin inadvertently.
	stdin := sys->fildes(0);
	nullfd := sys->open("/dev/null", Sys->OREAD);
	sys->dup(nullfd.fd, 0);
	nullfd = nil;

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);
	sets = load Sets Sets->PATH;
	if(sets == nil)
		badmodule(Sets->PATH);
	sets->init();
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		badmodule(Bufio->PATH);
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		badmodule(Readdir->PATH);
	attributes = load Attributes Attributes->PATH;
	if(attributes == nil)
		badmodule(Attributes->PATH);
	archives = load Archives Archives->PATH;
	if(archives == nil)
		badmodule(Archives->PATH);
	archives->init();
	sexprs = load Sexprs Sexprs->PATH;
	if(sexprs == nil)
		badmodule(Sexprs->PATH);
	sexprs->init();
	format = load Format Format->PATH;
	if(format == nil)
		badmodule(Format->PATH);
	format->init();
	timetable = load Timetable Timetable->PATH;
	if(timetable == nil)
		badmodule(Timetable->PATH);
	timetable->init();
	styx = load Styx Styx->PATH;
	if (styx == nil)
		badmodule(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if (styxservers == nil)
		badmodule(Styxservers->PATH);
	styxservers->init(styx);

	nametree = load Nametree Nametree->PATH;
	if (nametree == nil)
		badmodule(Nametree->PATH);
	nametree->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		badmodule(Arg->PATH);

	timefd = sys->open("/dev/time", Sys->OREAD);
	if(timefd == nil){
		logerror(sys->sprint("cannot open /dev/time: %r"));
		raise "fail:no time";
	}
	starttime = now();

	loginterval := str2time("7d");
	dumpinterval := str2time("10s");
	unblacklistinterval := str2time("10m");
	restoring := 1;
	logfile := "";

	arg->setusage("scheduler [-n] [configfile]");
	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'n' =>
			restoring = 0;
		* =>
			arg->usage();
		}
	}
	cfg: ref Iobuf;
	if((argv = arg->argv()) != nil){
		if((cfg = bufio->open(relpath(hd argv, "/grid/master"), Sys->OREAD)) == nil){
			logerror(sys->sprint("cannot open %q: %r", relpath(hd argv, "/grid/master")));
			raise "fail:error";
		}
	}else
		cfg = bufio->open("/grid/master/config", Sys->OREAD);
	if(cfg != nil){
		while(((se, err) := Sexp.read(cfg)).t0 != nil){
			attr := se.op();
			args := se.args();
			if(len args != 1 || (hd args).islist()){
				logerror(sys->sprint("invalid config line %s", se.text()));
				continue;
			}
			val := (hd args).astext();
			case attr {
			"loginterval" =>
				if((t := str2time(val)) > big 0)
					loginterval = t;
				else
					logerror(sys->sprint("bad log interval %q", val));
			"dumpinterval" =>
				if((t := str2time(val)) > big 0)
					dumpinterval = t;
				else
					logerror(sys->sprint("bad dump interval %q", val));
			"unblacklistinterval" =>
				if((t := str2time(val)) > big 0)
					unblacklistinterval = t;
				else
					logerror(sys->sprint("bad unblacklist interval %q", val));
			"root" =>
				root = val;
			"log" =>
				logfile = val;
			"adminid" =>
				adminid = val;
			"workerid" =>
				workerid = val;
			"logstyx" =>
				Debugstyx = int val;
			"taskgenpath" =>
				taskgenpath = val;
			"verbose" =>
				Verbose = int val;
			}
		}
		if(err != nil){
			logerror(sys->sprint("config file error: %s", err));
			raise "fail:config error";
		}
	}
	cfg = nil;

	(ok, stat) := sys->stat(root);
	if(ok == -1 || (stat.mode & Sys->DMDIR) == 0){
		logerror(sys->sprint("%q does not exist or is not a directory", root));
		raise "fail:no root";
	}

	if(arg->argv() != nil)
		arg->usage();
	arg = nil;

	sync := chan of int;
	spawn logfileproc(loginterval, logfile, sync);
	if(<-sync == -1)
		raise "fail:cannot make logfile";
	dumpfile = root + "/dump";

	tags = Table[ref Tag].new(103, nil);
	tagslock = chan[1] of int;
	nodes = Table[ref Node].new(97, nil);
	allnodes = Strhash[ref Nodeinfo].new(97, nil);
	jobs = Table[ref Job].new(7, nil);
	times = Table[ref Nodetimes].new(7, nil);
	timeslock = chan[1] of int;

	formats = format->spec2fmt(fmtspecs);

	log(sys->sprint("scheduler start %bd", starttime));

	navops: chan of ref Styxservers->Navop;
	(tree, navops) = nametree->start();

	tree.create(big Qroot, dir(Qroot, ".", 8r555 | Sys->DMDIR, "admin", "admin"));
	tree.create(big Qroot, dir(Qtask, "task", 8r660, "worker", "worker"));
	tree.create(big Qroot, dir(Qreconnect, "reconnect", 8r660, "worker", "worker"));
	tree.create(big Qroot, dir(Qstoptask, "stoptask", 8r440, "worker", "worker"));
	tree.create(big Qroot, dir(Qattrs, "attrs", 8r660, "worker", "worker"));
	tree.create(big Qroot, dir(Qnodename, "nodename", 8r666, "admin", "admin"));
	tree.create(big Qroot, dir(Qadmindir, "admin", 8r550 | Sys->DMDIR, "admin", "submit"));
	tree.create(big Qadmindir, dir(Qformats, "formats", 8r440, "admin", "submit"));
	tree.create(big Qadmindir, dir(Qclone, "clone", 8r660, "admin", "submit"));
	tree.create(big Qadmindir, dir(Qjobs, "jobs", 8r660, "admin", "monitor"));
	tree.create(big Qadmindir, dir(Qnodes, "nodes", 8r660, "admin", "monitor"));
	tree.create(big Qadmindir, dir(Qgroup, "group", 8r440, "admin", "monitor"));
	tree.create(big Qadmindir, dir(Qctl, "ctl", 8r220, "admin", "admin"));
	tree.create(big Qadmindir, dir(Qtimesdir, "times", 8r770 | Sys->DMDIR, "admin", "admin"));
	tree.create(big Qtimesdir, dir(Qtimes | (maxtimesid<<QShift), "always", 8r440, "admin", "admin"));
	Always = ref Nodetimes(maxtimesid++, "always", timetable->new("always").t0, 2, "always");
	times.add(Always.id, Always);

	q: ref Jobqueue;
	if(restoring){
		e: string;
		(q, e) = restore(root + "/dump");
		if(q == nil && e != nil){
			logerror(sys->sprint("cannot restore: %s", e));
			log(nil);
			# XXX should stop logfileproc too.
			navops <-= nil;
			raise "fail:cannot restore";
		}
	}
	if(uniqid == nil)
		uniqid = sys->sprint("%ux", randomint());
	if(q == nil)
		q = ref Jobqueue;
	sys->pctl(Sys->FORKNS, nil);		# newpgrp?

	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(stdin, Navigator.new(navops), big Qroot);
	srv.ingroup = ingroup;

	taskreqch = chan of (ref Node, chan of (ref Job, ref Taskinst));
	taskreconnectch = chan of (ref Node, string, chan of (ref Job, ref Taskinst, string));
	taskflushch = chan of chan of (ref Job, ref Taskinst);
	taskendch = chan of (int, ref Job, ref Taskinst, string);
	taskmonlock = chan of int;
	kicktaskmon = chan[1] of int;
	jobctlch = chan of ref Jobctl;
	getjobsch = chan of chan of list of ref Job;
	timeschanged = chan of int;
	fidlock = chan[1] of int;
	allnodeslock = chan[1] of int;
	clunked = chan of ref Fid;
	newnodech = chan of (string, chan of ref Nodeinfo);
	dumpch = chan of chan of string;
	if(Debugstyx){
		styxoutput = sys->create(root+"/styx.out", Sys->OWRITE, 8r666);
		srv.replychan = chan of ref Rmsg;
		tmsgsend = chan of (string, ref Tmsg);
		spawn printreplies();
	}
	if(Debugmem)
		memfd = sys->open("#c/memory", Sys->OREAD);

	if(dumpinterval > big 0)
		spawn dumpproc(dumpinterval);

	spawn unblacklistproc(int (unblacklistinterval / big 1000));

	spawn timepromptproc(timeschanged, kicktaskmon);
	spawn taskmonproc(q, taskreqch, taskreconnectch, taskendch, getjobsch, jobctlch);
	serve(tchan);
	# XXX should shut down more cleanly
	navops <-= nil;
}

printreplies()
{
	sys->fprint(styxoutput, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n");
	sys->fprint(styxoutput, "%.10bd start %bd\n", now(), starttime);
	for(;;)alt{
	m := <-srv.replychan =>
		if(m == nil)
			return;
		sys->fprint(styxoutput, "%.10bd %s %ux\n", now(), m.text(), m);
		srv.replydirect(m);
	(kind, m) := <-tmsgsend =>
		if(kind == nil)
			sys->fprint(styxoutput, "%.10bd %s %ux\n", now(), m.text(), m);
		else
			sys->fprint(styxoutput, "%.10bd %s %ux\n", now(), kind, m);
	}
}

badmodule(p: string)
{
	logerror(sys->sprint("cannot load %s: %r", p));
	raise "fail:bad module";
}

serve(tchan: chan of ref Tmsg)
{
	reqdone = chan of chan of (ref Tag,  ref Fid);

Serve:
	for(;;)alt{
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		if(Debugstyx)
			tmsgsend <-= (nil, gm);
		pick m := gm {
		Readerror =>
			logerror(sys->sprint("fatal read error: %s", m.error));
			break Serve;
		Open =>
			(fid, nil, nil, err) := srv.canopen(m);
			if(err != nil)
				srv.reply(ref Rmsg.Error(m.tag, err));
			else if(fid.qtype & Sys->QTDIR)
				srv.default(m);
			else if((int fid.path & QMask) == Qclone){
				n := fidnode(fid);
				if(n.info == nil)
					setnodename(n, hostname(n.ipaddr));	# XXX single-threaded DNS lookup
				j := Job.new(-1, nil, fid.session.uname);
				q := qid(Qjobctl | (j.id << QShift));
				fid.open(m.mode, q);
				srv.reply(ref Rmsg.Open(m.tag, q, 0));
			}
			else
				sendrequest(m, fid);
		Create =>
			# XXX cancreate should check that name doesn't contain slash/control chars.
			(fid, nil, d, err) := srv.cancreate(m);
			if(err != nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(fid.path != big Qtimesdir || (d.mode & Sys->DMDIR)){
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			id := maxtimesid++;
			d.qid.path = big (Qtimes | id << QShift);
			timeslock <-= 1;
			q := Qtimes | (id<<QShift);
			tree.create(big Qtimesdir, dir(q, d.name, 8r660&d.mode, "admin", "admin"));
			times.add(id, ref Nodetimes(id, m.name, nil, 1, nil));
			<-timeslock;
			fid.open(m.mode, qid(q));
			srv.reply(ref Rmsg.Create(m.tag, Sys->Qid(big q, 0, Sys->QTFILE), srv.iounit()));
		Remove =>
			(fid, qid, err) := srv.canremove(m);
			if(fid == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			tree.remove(fid.path);
			if((qid & big QMask) == big Qtimes){
				# XXX check refcount
				timeslock <-= 1;
				id := int (qid >> QShift);
				t := times.find(id);
				if(t.refcount > 1){
					<-timeslock;
					srv.delfid(fid);
					srv.reply(ref Rmsg.Error(m.tag, "file in use"));
					break;
				}
				times.del(id);
				<-timeslock;
			}
			srv.delfid(fid);
			srv.reply(ref Rmsg.Remove(m.tag));
		Read =>
			(fid, err) := srv.canread(m);
			if(err != nil)
				srv.reply(ref Rmsg.Error(m.tag, err));
			else if(fid.qtype & Sys->QTDIR)
				srv.read(m);
			else
				sendrequest(m, fid);
		Write =>
			(fid, err) := srv.canwrite(m);
			if(err != nil)
				srv.reply(ref Rmsg.Error(m.tag, err));
			else
				sendrequest(m, fid);
		Flush =>
			tag := tags.find(m.oldtag);
			if(tag != nil){
				tag.flushc <-= 1;
				tagslock <-= 1;
				# reply might have been sent and tag deleted, so check again
				if(tags.find(m.oldtag) != nil)
					tags.del(m.oldtag);
				else if(Debugstyx)
					tmsgsend <-= ("flushnotag", m);
				<-tagslock;
			}else if(Debugstyx)
				tmsgsend <-= ("oldflush", m);
			srv.reply(ref Rmsg.Flush(m.tag));
		Walk =>
			fid := srv.getfid(m.fid);
			if(fid == nil)
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
			else{
				j: ref Job;
				oj := jobs.find(int fid.path >> QShift);
				fid = srv.walk(m);
				if(fid != nil)
					j = jobs.find(int fid.path >> QShift);
				if(j != nil)
					j.incref();			# XXX job might have just disappeared.
				if(oj != nil && m.newfid == m.fid)
					oj.decref();
			}
		Attach =>
			fid := srv.attach(m);
			if(fid != nil){
				n := ref Node(nil, nil, m.aname, m.uname, groupmembership(fid.session.uname), chan[1] of int, chan of string, chan of string, chan of int);
				n.active <-= 1;
				nodes.add(maxconnid, n);
				fid.session.handle = maxconnid++;
				spawn bufferproc(n.stoptask, n.getstoptask, n.stopbufproc);
				log(sys->sprint("worker arrive %q %q", n.ipaddr, m.uname));
			}
		Clunk =>
			fid := srv.getfid(m.fid);
			if(fid == nil)
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
			else
				sendrequest(m, fid);
		* =>
			srv.default(gm);
		}
	(h, c) := <-newnodech =>
		allnodeslock <-= 1;
		info := allnodes.find(h);
		if(info == nil){
			info = ref Nodeinfo(maxnodeid++, h, nil, 0, NOTIME, 0, 0, 0, Attrs[string](nil), nil, Always);
			info.times.refcount++;		# XXX timeslock?
			allnodes.add(h, info);
		}
		<-allnodeslock;
		c <-= info;
	fid := <-clunked =>
		if(fid != nil){
			if(fid.session.refcount == 0){
				n := fidnode(fid);
				<-n.active;
				n.stopbufproc <-= 1;
				n.active <-= 0;
				nodes.del(fid.session.handle);
				if(n.info == nil)
					log(sys->sprint("worker leave '' %q", n.ipaddr));
				else{
					if(--n.info.connected == 0)
						n.info.disconnecttime = now();
					log(sys->sprint("worker leave %q %q", n.info.name, n.ipaddr));
					n.info.delipaddr(n.ipaddr);
				}
			}
			j := jobs.find(int fid.path >> QShift);
			if(j != nil)
				j.decref();
		}
	req := <-reqdone =>
		if(reqidle >= Maxreqidle)
			req <-= (nil, nil);
		else{
			reqpool = req :: reqpool;
			reqidle++;
		}
	reply := <-dumpch =>
		if(dumpfile == nil)
			reply <-= "no dump file has been set";
		else
			reply <-= dump(dumpfile);
	}
}

groupmembership(uname: string): int
{
	groups := 0;
	case (adminid != nil)<<1 | (workerid != nil){
	2r00 =>
		# everyone has all privileges
		groups = Gadmin;
	2r10 =>
		# admin has admin rights; everyone else is only a worker
		if(uname == adminid)
			groups = Gadmin;
		else
			groups = Gworker;
	2r01 =>
		# worker has worker rights; everyone else is an admin
		if(uname == workerid)
			groups = Gworker;
		else
			groups = Gadmin;
	2r11 =>
		# worker has worker rights; admin has all rights; others can monitor and submit
		if(uname == workerid)
			groups = Gworker;
		else if(uname == adminid)
			groups = Gadmin;
		else
			groups = Gsubmit;
	}
	if(groups & Gadmin)
		groups |= Gworker|Gsubmit|Gmonitor;
	if(groups & Gsubmit)
		groups |= Gmonitor;
#sys->print("group membership for %s is %#x\n", uname, groups);
	return groups;
}

# called by styxservers to find out group membership.
ingroup(nil: ref Styxserver, fid: ref Fid, g: string): int
{
	n := fidnode(fid);
	gid := 0;
	case g {
	"admin" =>
		gid = Gadmin;
	"submit" =>
		gid = Gsubmit;
	"monitor" =>
		gid = Gmonitor;
	"worker" =>
		gid = Gworker;
	}
#sys->print("%s member of %s: %d\n", fid.session.uname, g, (n.groups & gid) != 0);
	return n.groups & gid;
}
	
sendrequest(m: ref Styx->Tmsg, fid: ref Fid)
{
	c: chan of (ref Tag, ref Fid);
	tag := ref Tag(m, chan[1] of int);
	tagslock <-= 1;
	if(tags.add(m.tag, tag) == 0 && Debugstyx)
		tmsgsend <-= ("duptag", m);
	<-tagslock;
	if(reqpool == nil){
		c = chan of (ref Tag, ref Fid);
		spawn requestproc(c);
	}else{
		(c, reqpool) = (hd reqpool, tl reqpool);
		reqidle--;
	}
	c <-= (tag, fid);
}

styxreply(m: ref Tmsg, r: ref Rmsg)
{
	tagslock <-= 1;
	if(tags.del(m.tag) == 0 && Debugstyx)
		tmsgsend <-= ("donedeleted", m);
	<-tagslock;
	srv.reply(r);
}

requestproc(req: chan of (ref Tag, ref Fid))
{
	for(;;){
		(tag, fid) := <-req;
		if(tag == nil)
			break;
		r := request(tag.m, fid, tag.flushc);
		if(r != nil){
			alt{
			tag.flushc <-= 1 =>
				styxreply(tag.m, r);
				<-tag.flushc;
			* =>
				;
			}
		}
		reqdone <-= req;
	}
}

request(gm: ref Tmsg, fid: ref Fid, flushc: chan of int): ref Rmsg
{
	path := int fid.path;
	job := jobs.find(path >> QShift);
	path &= QMask;
	pick m := gm {
	Open =>
		n := fidnode(fid);
		# make sure we've create some node info even if the client
		# hasn't given us a node name
		if(n.info == nil && path != Qnodename)
			setnodename(n, hostname(n.ipaddr));
		case path {
		Qtask =>
			opentask(m, fid, flushc);
			return nil;
		Qmonitor =>
			if(!job.done && job.taskgen == nil)
				return ref Rmsg.Error(m.tag, "job has not been started");
			alt{
			flushc <-= 1 =>
				sfid := newfid(fid);
				sfid.statsversion = -1;
				open(srv, m);
				<-flushc;
			* =>
				;
			}
			return nil;
		Qreconnect =>
			alt{
			flushc <-= 1 =>
				sfid := newfid(fid);
				sfid.state = Tstartstate;
				open(srv, m);
				<-flushc;
			* =>
				;
			}
			return nil;
		Qjobdata =>
			alt{
			flushc <-= 1 =>
				e := openjobdata(m, job, fid);
				if(e != nil)
					styxreply(m, ref Rmsg.Error(m.tag, e));
				else
					open(srv, m);
				<-flushc;
			* =>
				;
			}
			return nil;
		Qattrs =>
			alt{
			flushc <-= 1 =>
				if(open(srv, m) != nil && (m.mode & Sys->OTRUNC)){
					log(sys->sprint("cleanattrs %q %q", n.info.name, n.info.ipaddr));
					n.info.attrs = Attrs[string].new();
				}
				<-flushc;
			* =>
				;
			}
			return nil;
		Qnodes or
		Qjobs =>
			alt{
			flushc <-= 1 =>
				newfid(fid);
				open(srv, m);
				<-flushc;
			* =>
				;
			}
			return nil;
		Qjobctl or
		Qduration or
		Qlog or
		Qnodename or
		Qformats or
		Qctl or
		Qjobgroup or
		Qjobdescription or
		Qjobid or
		Qjobnodes or
		Qgroup or
		Qstoptask or
		Qtimes =>
			alt{
			flushc <-= 1 =>
				open(srv, m);
				<-flushc;
			* =>
				;
			}
			return nil;
		* =>
			return ref Rmsg.Error(m.tag, "what was i thinking3?");
		}
	Write =>
		if(!fid.isopen)
			return ref Rmsg.Error(m.tag, "file not open");
		sfid := getfid(fid);
		case path {
		Qnodename =>
			n := fidnode(fid);
			if(n.info != nil)
				return ref Rmsg.Error(m.tag, "node name is already set");
			alt{
			flushc <-= 1 =>
				if(setnodename(n, string m.data) == -1)
					styxreply(m, ref Rmsg.Error(m.tag, "node name is already set"));
				else
					styxreply(m, ref Rmsg.Write(m.tag, len m.data));
				<-flushc;
			* =>
				;
			}
			return nil;
		Qctl or
		Qjobctl =>
			alt{
			flushc <-= 1 =>
				ctl := string m.data;
				n := fidnode(fid);
				if(job == nil)
					log(sys->sprint("sched ctl%d %q %q %q", m.tag, n.info.name, n.ipaddr, cleanstr(ctl)));
				else
					log(sys->sprint("job ctl%d %q %q %q %q", m.tag, n.info.name, n.ipaddr, job.idtext(), cleanstr(ctl)));
				e := jobctl(job, str->unquoted(ctl));
				if(e != nil){
					log(sys->sprint("ctl%d error %q", m.tag, e));
					styxreply(m, ref Rmsg.Error(m.tag, e));
				}else{
					log(sys->sprint("ctl%d done", m.tag));
					styxreply(m, ref Rmsg.Write(m.tag, len m.data));
				}
				<-flushc;
			* =>
				;
			}
			return nil;
		Qreconnect or
		Qtask =>
			# reconnect is the same as task save for the initial write.
			if(path == Qreconnect && sfid.state == Treadtaskid){
				alt{
				flushc <-= 1 =>
					e := writereconnectid(fid, sfid, string m.data);
					if(e != nil)
						styxreply(m, ref Rmsg.Error(m.tag, e));
					else{
						styxreply(m, ref Rmsg.Write(m.tag, len m.data));
						sfid.state++;
					}
					<-flushc;
				* =>
					;
				}
				return nil;
			}
			e := writetask(sfid, m, flushc);
			if(e != nil)
				return ref Rmsg.Error(m.tag, e);
			return nil;
		Qattrs =>
			(attrs, e) := string2attrs(string m.data);
			if(e != nil)
				return ref Rmsg.Error(m.tag, e);
			alt{
			flushc <-= 1 =>
				;
			* =>
				return nil;
			}
			n := fidnode(fid);
			log(sys->sprint("addattrs %q %q %q", n.info.name, n.ipaddr, cleanstr(string m.data)));
			# XXX make this atomic?
			if(path == Qattrs)
				n.info.attrs = n.info.attrs.merge(attrs);
			styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			<-flushc;
			kicktaskmon <-= 1;
			return nil;
		Qjobdata =>
			reply := chan of string;
			sfid.write <-= (m.data, reply, flushc);
			case e := <-reply {
			"flushed" =>
				return nil;
			"" =>
				styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			* =>
				styxreply(m, ref Rmsg.Error(m.tag, e));
			}
			<-flushc;
			return nil;
		Qjobdescription =>
			alt{
			flushc <-= 1 =>
				;
			* =>
				return nil;
			}
			job.description = string m.data;
			log(sys->sprint("job description %q %q", job.idtext(), cleanstr(job.description)));
			styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			<-flushc;
			return nil;
		Qtimes =>
			if(m.offset != big 0)
				return ref Rmsg.Error(m.tag, "too big");
			alt{
			flushc <-= 1 =>
				;
			* =>
				return nil;
			}
			s := string m.data;
			(t, err) := timetable->new(s);
			if(t == nil){
				styxreply(m, ref Rmsg.Error(m.tag, err));
				<-flushc;
				return nil;
			}
			timeslock <-= 1;
			n := times.find(int (fid.path >> QShift));
			if(n == nil){
				<-timeslock;
				styxreply(m, ref Rmsg.Error(m.tag, "file has been removed"));
				<-flushc;
				return nil;
			}
			n.t = t;
			n.text = s;
			<-timeslock;
			styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			<-flushc;
			timeschanged <-= 1;
			return nil;
		Qjobs or
		Qnodes or
		Qmonitor =>
			if(m.offset != big 0)
				return ref Rmsg.Error(m.tag, "too big");
			(se, nil, err) := Sexp.unpack(m.data);
			if(se == nil)
				return ref Rmsg.Error(m.tag, err);
			fmt: array of Fmt;
			(fmt, err) = format->se2fmt(fmtspecs[path].fields, se);
			if(err != nil)
				return ref Rmsg.Error(m.tag, "bad format: "+err);
			alt{
			flushc <-= 1 =>
				sfid.fmt = fmt;
				styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			* =>
				;
			}
			return nil;
		* =>
			return ref Rmsg.Error(m.tag, "what was i thinking2?");
		}
	Read =>
		if(!fid.isopen)
			return ref Rmsg.Error(m.tag, "file not open");
		sfid := getfid(fid);
		case path {
		Qjobctl =>
			return styxservers->readstr(m, string job.id);
		Qreconnect or
		Qtask =>
			e := taskread(path, sfid, m, flushc);
			if(e != nil)
				return ref Rmsg.Error(m.tag, e);
			return nil;
		Qstoptask =>
			n := fidnode(fid);
			alt{
			<-flushc =>
				;
			clientid := <-n.getstoptask =>
				alt{
				flushc <-= 1 =>
					m.offset = big 0;
					r := styxservers->readstr(m, clientid);
					log(sys->sprint("stoptask read %d %q", len r.data, clientid));
					styxreply(m, r);
					<-flushc;
				* =>
					# we've been flushed: send clientid to next reader
					stoptask(n, clientid);
				}
			}
			return nil;
		Qmonitor =>
			m.offset = big 0;
			dt := now() - sfid.laststatstime;
			if(dt < Minmonitorrefresh && !job.done)
				sys->sleep(int (Minmonitorrefresh - dt));
			st: string;
			do{
				(v, stats) := job.getstats(sfid.statsversion, flushc);

				# if request has been flushed, don't reply.
				if(v == -1 && stats == nil){
					if(Debugstyx)
						tmsgsend <-= ("flushed", m);
					return nil;
				}
				if(stats == nil)
					return ref Rmsg.Read(m.tag, nil);
				st = fmtstats(stats, sfid.fmt);
				sfid.statsversion = v;
			}while(st == sfid.laststats);
			alt{
			flushc <-= 1 =>
				;
			* =>
				if(Debugstyx)
					tmsgsend <-= ("flushed", m);
				sfid.statsversion--;	# request has been flushed; make sure we get update next time.
				return nil;
			}
			sfid.laststatstime = now();
			sfid.laststats = st;

			d := array of byte st;
			if(m.count < len d)
				styxreply(m, ref Rmsg.Error(m.tag, "read too small"));
			else
				styxreply(m, styxservers->readbytes(m, d));
			<-flushc;
			return nil;
		Qjobs =>
			if(m.offset == big 0)
				fid.data = array of byte jobsread(sfid.fmt);
			return styxservers->readbytes(m, fid.data);
		Qnodes =>  
			if(m.offset == big 0)
				fid.data = array of byte nodesread(sfid.fmt);
			return styxservers->readbytes(m, fid.data);
		Qformats =>
			s := "";
			for(l := format->spec2se(fmtspecs); l != nil; l = tl l)
				s += (hd l).text() + "\n";
			return styxservers->readbytes(m, array of byte s);
		Qgroup =>
			if(m.offset == big 0)
				fid.data = array of byte group2str(globalgroup);
			return styxservers->readbytes(m, fid.data);
		Qjobdata =>
			reply := chan of array of byte;
			sfid.read <-= (m.count, reply, flushc);
			d := <-reply;
			if(d == nil)		# flushed
				return nil;
			styxreply(m, ref Rmsg.Read(m.tag, d));
			<-flushc;
			return nil;
		Qjobgroup =>
			if(m.offset == big 0)
				fid.data = array of byte group2str(job.group);
			return styxservers->readbytes(m, fid.data);
		Qjobdescription =>
			if(m.offset == big 0)
				fid.data = array of byte job.description;
			return styxservers->readbytes(m, fid.data);
		Qjobid =>
			return styxservers->readstr(m, job.idtext());
		Qjobnodes =>
			return styxservers->readstr(m, jobnodes(job));
		Qduration =>
			return styxservers->readstr(m, string (now() - job.starttime));
		Qlog =>
			fd := sys->open(root+"/work/"+job.idtext()+"/log", Sys->OREAD);
			if(fd == nil)
				return ref Rmsg.Error(m.tag, sys->sprint("cannot open log: %r"));
			sys->seek(fd, m.offset, Sys->SEEKSTART);
			buf := array[m.count] of byte;
			n := sys->read(fd, buf, m.count);
			if(n == -1)
				return ref Rmsg.Error(m.tag, sys->sprint("%r"));
			return ref Rmsg.Read(m.tag, buf[0:n]);
		Qattrs =>
			return styxservers->readstr(m, attrs2string(fidnode(fid).info.attrs, '\n'));
		Qnodename =>
			if((info := fidnode(fid).info) == nil)
				return ref Rmsg.Error(m.tag, "no name has been set");
			return styxservers->readstr(m, info.name);
		Qtimes =>
			timeslock <-= 1;
			t := times.find(int (fid.path >> QShift));
			<-timeslock;
			if(t == nil)
				return ref Rmsg.Error(m.tag, "file has been removed");
			return styxservers->readstr(m, t.text);
		* =>
			return ref Rmsg.Error(m.tag, "what was i thinking1?");
		}
	Clunk =>
		alt{
		flushc <-= 1 =>
			;
		* =>
			return nil;
		}
		sfid := getfid(fid);
		if(sfid != nil){
			case path {
			Qtask or
			Qreconnect =>
				t := sfid.task;
				if(t == nil)
					break;		# possible for Qreconnect
				t.task.lock <-= 1;
				if(t.finish == nil){
					<-t.task.lock;
					taskendch <-= (Efinished, sfid.job, t, nil);
					break;
				}
				reply := chan of string;
				first := t.task.nok == 0;
				t.finish <-= (first, now() - t.starttime, reply);
				t.finish = nil;
				t.read = nil;
				t.write = nil;

				# this is done inside the lock so that nok is consistent (finishing must be serial):
				e := <-reply;
				if(e == nil)
					t.task.nok++;
				<-t.task.lock;
				status: int;
				case e {
				"" =>
					if(first)
						status = Eok;
					else
						status = Eduplicate;
				"disconnected" =>
					status = Edisconnect;
				* =>
					status = Eerror;
				}
				taskendch <-= (status, sfid.job, t, e);
			Qjobdata =>
				sfid.clunk <-= 1;
			}
			delfid(sfid);
		}
		srv.delfid(fid);
		styxreply(m, ref Rmsg.Clunk(m.tag));
		<-flushc;
		clunked <-= fid;
		return nil;
	* =>
		return ref Rmsg.Error(gm.tag, "oh dear");	
	}
}

setnodename(n: ref Node, name: string): int
{
	allnodeslock <-= 1;
	if(n.info != nil){
		<-allnodeslock;
		return -1;
	}
	info := allnodes.find(name);
	if(info == nil){
		info = ref Nodeinfo(maxnodeid++, name, n.ipaddr, 0, NOTIME, 0, 0, 0, Attrs[string](nil), nil, Always);
		Always.refcount++;
		allnodes.add(name, info);
	} else
		info.ipaddr = n.ipaddr;
	info.connected++;
	n.info = info;
	<-allnodeslock;
	log(sys->sprint("worker name %q %q", name, n.ipaddr));
	return 0;
}

openjobdata(m: ref Tmsg.Open, job: ref Job, fid: ref Fid): string
{
	job.lock <-= 1;
	if(job.taskgen == nil){
		<-job.lock;
		return "job not active";
	}
	read := chan of Readreq;
	write := chan of Writereq;
	clunk := chan of int;
	e := job.taskgen.opendata(fid.session.uname, m.mode, read, write, clunk);
	if(e == nil){
		sfid := newfid(fid);
		sfid.job = job;
		sfid.read = read;
		sfid.write = write;
		sfid.clunk = clunk;
	}
	<-job.lock;
	return e;
}

# perform the rather intricate flush dance, making sure that
# a) we never send a reply after we've been flushed and
# b) we keep taskmonproc happy and undeadlocked by being ready to receive from it
# whenever it might wish to send to us.
opentask(m: ref Tmsg.Open, fid: ref Fid, flushc: chan of int)
{
	reply := chan of (ref Job, ref Taskinst);
	n := fidnode(fid);
	log(sys->sprint("task open %q %q", n.info.name, n.ipaddr));
	taskreqch <-= (n, reply);
	alt{
	(j, t) := <-reply =>
		alt{
		flushc <-= 1 =>
			if(t == nil){
				log(sys->sprint("task-nowork %q %q", n.info.name, n.ipaddr));
				styxreply(m, ref Rmsg.Error(m.tag, "no work to do"));
			}else{
				path := int fid.path;
				q := qid(path);
				styxreply(m, ref Rmsg.Open(m.tag, qid(path), 0));
				fid.open(m.mode, q);
				sfid := newfid(fid);
				sfid.task = t;
				sfid.job = j;
				sfid.state = Tstartstate;
				n.lasttask = t.task.idtext();
			}
			<-flushc;
		* =>
			log(sys->sprint("opentask unluckyflush %q %q %q", n.info.name, n.ipaddr, t.task.about()));
			taskendch <-= (Eerror, j, t, "interrupted");
		}
	<-flushc =>
		# request has been flushed; either notify taskmonproc
		# to flush it, or recycle the task if it didn't get it in time.
		log(sys->sprint("opentask flush %q %q", n.info.name, n.ipaddr));
		alt{
		taskflushch <-= reply =>
			;
		(j, t) := <-reply =>
			# taskmon didn't get flush request in time, so send task back for re-issue.
			log(sys->sprint("opentask unluckyflush2 %q %q %q", n.info.name, n.ipaddr, t.task.about()));
			taskendch <-= (Eerror, j, t, "interrupted");
		}
	}
}

# parse the external form of a task id.
# return (jobid, jobuniq, taskid)
parsetaskid(id: string): (int, string, int)
{
	# format of id is: %ux.%d#%d
	# jobuniq.jobid#taskuniq
	s: string;
	(s, id) = str->splitl(id, ".");
	jobuniq := s;
	id = str->drop(id, ".");
	(s, id) = str->splitl(id, "#");
	jobid := int s;
	s = str->drop(id, "#");
	taskuniq := int s;

	if(jobuniq == nil || jobid == 0 || taskuniq == 0)
		return (-1, nil, -1);

	return (jobid, jobuniq, taskuniq);
}

writereconnectid(fid: ref Fid, sfid: ref Sfid, id: string): string
{
	# strip off deadline field, if written by unaware clients.
	for(i := 0; i < len id; i++)
		if(id[i] == ' '){
			id = id[0:i];
			break;
		}

	reply := chan of (ref Job, ref Taskinst, string);
	n := fidnode(fid);
	taskreconnectch <-= (n, id, reply);
	(j, t, e) := <-reply;
	if(j == nil){
		log(sys->sprint("task failreconnect %q %q %q %q", n.info.name, n.ipaddr, id, e));
		return e;
	}
	sfid.task = t;
	sfid.job = j;
	sfid.state = Tstartstate;
	log(sys->sprint("task reconnected %q %q %q", n.info.name, n.ipaddr, t.task.about()));
	return nil;
}

writetask(sfid: ref Sfid, m: ref Tmsg.Write, flushc: chan of int): string
{
	t := sfid.task;
	if(t == nil)
		return Egreg;
	if(t.stopped)
		return "task has been stopped";
	t.task.lock <-= 1;
	if(t.write == nil){
		<-t.task.lock;
		return "task has completed";
	}
	case sfid.state {
	Treadtaskid =>
		<-t.task.lock;
		return "must read task id";
	Twritetaskid =>
		<-t.task.lock;
		if(len m.data == 0)
			return "invalid task id";
		alt {
		flushc <-= 1 =>
			;
		* =>
			return nil;
		}
		t.clientid = string m.data;
		sfid.state++;
		if(Verbose)
			log(sys->sprint("task writeid %q %q %q %d", t.node.info.name, t.node.ipaddr, t.task.about(), len m.data));
		styxreply(m, ref Rmsg.Write(m.tag, len m.data));
		<-flushc;
	Ttaskcomms =>
		reply := chan of string;
		t.write <-= (m.data, reply, flushc);
		<-t.task.lock;
		if((e := <-reply) != nil){
			if(e == "flushed")
				return nil;
			styxreply(m, ref Rmsg.Error(m.tag, e));
			<-flushc;
			log(sys->sprint("task writeerror %q %q %q %d %q", t.node.info.name, t.node.ipaddr, t.task.about(), len m.data, e));
		}else{
			if(Verbose)
				log(sys->sprint("task write %q %q %q %d", t.node.info.name, t.node.ipaddr, t.task.about(), len m.data));
			styxreply(m, ref Rmsg.Write(m.tag, len m.data));
			<-flushc;
			t.task.incstat(Sdataout, len m.data);
		}
	* =>
		<-t.task.lock;
		return Egreg;
	}
	return nil;
}

taskread(path: int, sfid: ref Sfid, m: ref Tmsg.Read, flushc: chan of int): string
{
	if(sfid == nil)
		return "stale task";
	if(path == Qreconnect && sfid.state == Treadtaskid)
		return "must write old task id";
	t := sfid.task;
	if(t.stopped)
		return "task has been stopped";
	t.task.lock <-= 1;
	if(t.read == nil){
		<-t.task.lock;
		return "task has completed";
	}
	data: array of byte;
	case sfid.state {
	Treadtaskid =>
		alt{
		flushc <-= 1 =>
			;
		* =>
			<-t.task.lock;
			return nil;		# flushed
		}
		<-t.task.lock;
		now := epochtime();
		(in, deadline) := t.node.info.times.get(now);
		deadline -= now;
		if(in == 0)
			deadline = 0;		# XXX perhaps could give EOF if this happens?
		data = array of byte (t.task.idtext()+" "+string deadline);
		sfid.state++;
		if(Verbose)
			log(sys->sprint("task readtask %q %q %q %d", t.node.info.name, t.node.ipaddr, t.task.about(), len data));
	Twritetaskid or		# allow reads before taskid is written.
	Ttaskcomms =>
		# task gen must commit to the read for us.
		reply := chan of array of byte;
		t.read <-= (m.count, reply, flushc);
		<-t.task.lock;
		data = <-reply;
		t.task.incstat(Sdatain, len data);
		if(data == nil)
			return nil;		# flushed
		if(Verbose)
			log(sys->sprint("task read %q %q %q %d", t.node.info.name, t.node.ipaddr, t.task.about(), len data));
	}
	if(len data > m.count)
		data = data[0:m.count];
	styxreply(m, ref Rmsg.Read(m.tag, data));
	<-flushc;
	return nil;
}

schedctl(argv: list of string): string
{
	case hd argv {
	"dump" =>
		if(len argv != 1)
			return "usage: dump";
		reply := chan of string;
		dumpch <-= reply;
		return <-reply;
	"group" =>
		fidlock <-= 1;		# arbitrary lock
		e: string;
		(globalgroup, e) = groupctl(globalgroup, tl argv);
		<-fidlock;
		allnodeslock <-= 1;
		for(i := 0; i < len allnodes.items; i++){
			for(nl := allnodes.items[i]; nl != nil; nl = tl nl){
				n := (hd nl).t1;
				if(n.blacklisted && globalgroup.holds(n.id)){
					log(sys->sprint("node unblacklist %q %q", n.name, n.ipaddr));
					n.blacklisted = 0;
				}
			}
		}
		<-allnodeslock;
		kicktaskmon <-= 1;
		return e;
	"setgroup" or
	"teardown" =>
		nongroup := hd argv == "setgroup";
		for(i := 0; i < len jobs.items; i++)
			for(jl := jobs.items[i]; jl != nil; jl = tl jl)
				jobctlch <-= ref Jobctl.Teardown((hd jl).t1, nongroup);
		return nil;
	"delnode" =>
		for(argv = tl argv; argv != nil; argv = tl argv){
			allnodeslock <-= 1;
			n := allnodes.find(hd argv);
			if(n != nil && n.connected == 0)
				allnodes.del(hd argv);
			<-allnodeslock;
		}
		return nil;
	"times" =>
		# times timetable node...
		if(len argv < 3)
			return "usage: times timetable node...";
		tname := hd tl argv;
		nt: ref Nodetimes;
		timeslock <-= 1;
		for(i := 0; i < len times.items; i++)
			for(tt := times.items[i]; tt != nil; tt = tl tt)
				if((hd tt).t1.name == tname)
					nt = (hd tt).t1;
		<-timeslock;
		if(nt == nil)
			return "unknown timetable";
		allnodeslock <-= 1;
		for(argv = tl tl argv; argv != nil; argv = tl argv){
			info := allnodes.find(hd argv);
			if(info == nil){
				<-allnodeslock;
				newnodech <-= (hd argv, reply := chan of ref Nodeinfo);
				info = <-reply;
				allnodeslock <-= 1;
			}
			if(info.times != nil)
				info.times.refcount--;
			info.times = nt;
			info.times.refcount++;
		}
		<-allnodeslock;
		timeschanged <-= 1;
		return nil;
	* =>
		return "unknown control request";
	}
}

jobctl(job: ref Job, argv: list of string): string
{
	if(argv == nil)
		return "bad control request";
	if(job == nil)
		return schedctl(argv);
	case hd argv {
	"load" =>		# usage: load taskgen [arg...]
		job.lock <-= 1;
		if(job.done){
			<-job.lock;
			return "job is already complete";
		}
		if(job.taskgen != nil){
			<-job.lock;
			return "job has already been loaded";
		}
		(taskgen, err) := Taskgen.new(job.idtext(), nil, kicktaskmon, tl argv);
		if(taskgen == nil){
			<-job.lock;
			return err;
		}
		job.starttime = now();
		job.taskgen = taskgen;
		job.setstat(Stotal, job.taskgen.taskcount());
		job.argv = tl argv;
		<-job.lock;
		job.incref();
	"start" =>		# start/restart job
		if(tl argv != nil)
			return "bad control request";
		job.lock <-= 1;
		if(job.taskgen == nil){
			<-job.lock;
			return "job has not been loaded";
		}
		<-job.lock;
		jobctlch <-= ref Jobctl.Start(job);
		return nil;
	"stop" =>		# stop job (temporarily)
		jobctlch <-= ref Jobctl.Stop(job);
	"delete" =>	# delete job (when last reference is dropped)
		jobctlch <-= ref Jobctl.Delete(job);
		job.decref();
	"teardown" =>	# forcibly stop all currently active tasks in job
		jobctlch <-= ref Jobctl.Teardown(job, 0);
	"setgroup" =>	# forcibly stop all currently active tasks outside the job's group
		jobctlch <-= ref Jobctl.Teardown(job, 1);
	"priority" =>	# usage: priority low|high|jobid
		if(job.taskgen == nil)
			return "job has not been started";
		#  for "job n", task gets a pri just lower than job n
		if(len argv != 2)
			return "bad control request";
		case hd tl argv {
		"high" =>
			jobctlch <-= ref Jobctl.Priority(job, nil, 1);
		"low" =>
			jobctlch <-= ref Jobctl.Priority(job, nil, 0);
		* =>
			j := jobs.find(int hd tl argv);
			if(j == nil)
				return "no such job";
			jobctlch <-= ref Jobctl.Priority(job, j, 0);
		}
	"group" =>
		job.lock <-= 1;
		e: string;
		(job.group, e) = groupctl(job.group, tl argv);
		<-job.lock;
		if(e != nil)
			return e;
		kicktaskmon <-= 1;
	"prereq" =>	# usage: prereq module [arg...]
		if(tl argv == nil)
			return "bad control request";
		(p, e) := loadprereq(tl argv);
		if(p == nil)
			return e;
		job.prereq = p;
		job.prereqargs = tl argv;
		kicktaskmon <-= 1;
	"kick" =>
		kicktaskmon <-= 1;
	* =>
		return "unknown control request";
	}
	return nil;
}

loadprereq(argv: list of string): (Prereq, string)
{
	path := taskgenpath + "/" + hd argv + ".dis";		# XXX check for slashes?
	p := load Prereq path;
	if(p == nil)
		return (nil, sys->sprint("cannot load %q: %r", hd argv));
	if((e := p->init(argv)) != nil)
		return (nil, sys->sprint("prereq init failed: %s", e));
	return (p, nil);
}

# modify a group; on error, return the group unchanged with the error description.
groupctl(group: Set, argv: list of string): (Set, string)
{
	if(argv == nil)
		return (group, "bad control request");
	rq := hd argv;
	g := Sets->None;
	for(argv = tl argv; argv != nil; argv = tl argv)
		g = g.add(nodeid(hd argv, 1));
	case rq {
	"all" =>
		g = Sets->All;
	"none" =>
		g = Sets->None;
	"set" =>
		;
	"add" =>
		g = group.X(A|B, g);
	"del" =>
		g = group.X(A&~B, g);
	* =>
		return (group, "bad group control request");
	}
	return (g, nil);
}

jobsread(fmt: array of Fmt): string
{
	if(fmt == nil)
		fmt = formats[Qjobs].fields;
	s := "";
	c := chan of list of ref Job;
	getjobsch <-= c;

	# get queued jobs in priority (high first) order, leaving taskmon locked.
	l := rev(<-c);
	# add all the jobs that are not currently queued
	for(i := 0; i < len jobs.items; i++){
		for(jl := jobs.items[i]; jl != nil; jl = tl jl){
			(nil, j) := hd jl;
			if(j.queued == 0)
				l = j :: l;
		}
	}
	for(l = rev(l); l != nil; l = tl l){
		j := hd l;
		if(j.argv != nil){
			(nil, stats) := j.getstats(-1, chan of int);
			if(stats != nil){
				s += fmtjob(j, stats, fmt).text();
				s[len s] = '\n';
			}
		}
	}
	<-c;			# unlock taskmon
	return s;
}

nodesread(fmt: array of Fmt): string
{
	if(fmt == nil)
		fmt = formats[Qnodes].fields;
	s := "";
	taskmonlock <-= 1;
	for(i := 0; i < len allnodes.items; i++){
		for(l := allnodes.items[i]; l != nil; l = tl l){
			s += fmtnode((hd l).t1, fmt).text();
			s[len s] = '\n';
		}
	}
	<-taskmonlock;
	return s;
}

jobstatus(j: ref Job): string
{
	if(j.deleted)
		return "deleted";
	if(j.done)
		return "complete";
	if(j.queued)
		return "running";
	return "stopped";
}

jobnodes(job: ref Job): string
{
	s := "";
	# it's a snapshot so it's safe to look but not touch, without lock
	for(i := 0; i < len job.running.items; i++)
		for(l := job.running.items[i]; l != nil; l = tl l){
			n := (hd l).t1.node;
			if(n != nil && n.ipaddr != nil)
				s += n.ipaddr+"\n";
		}
	return s;
}

l2se(a: list of string): list of ref Sexp
{
	l: list of ref Sexp;
	for(; a != nil; a = tl a)
		l = ss(hd a) :: l;
	return rev(l);
}

fmtstats(stats: array of int, fmt: array of Fmt): string
{
	if(len fmt == 0)
		fmt = formats[Qmonitor].fields;
	s := "(\"" + string stats[fmt[0].kind] + "\"";
	for(i := 1; i < len fmt; i++)
		s += " \"" + string stats[fmt[i].kind] + "\"";
	s[len s] = ')';
	s[len s] = '\n';
	return s;
}

fmtjob(j: ref Job, stats: array of int, fmt: array of Fmt): ref Sexp
{
	f: list of ref Sexp;
	for(i := 0; i < len fmt; i++){
		item: ref Sexp;
		case fmt[i].kind {
		VJuniq =>
			item = ss(j.uniq);
		VJid =>
			item = ss(string j.id);
		VJstatus =>
			item = ss(jobstatus(j));
		VJncomplete =>
			item = ss(string stats[Scomplete]);
		VJntotal =>
			item = ss(string stats[Stotal]);
		VJargv =>
			item = sl(l2se(j.argv));
		VJprereq =>
			item = sl(l2se(j.prereqargs));
		* =>
			logerror(sys->sprint("missing format %d in job", fmt[i].kind));
			item = sl(nil);
		}
		f = item :: f;
	}
	return sl(rev(f));
}

fmtnode(n: ref Nodeinfo, fmt: array of Fmt): ref Sexp
{
	f: list of ref Sexp;
	for(i := 0; i < len fmt; i++){
		item: ref Sexp;
		case fmt[i].kind {
		VNname =>
			item = ss(n.name);
		VNipaddr =>
			item = ss(n.ipaddr);
		VNnconnected =>
			item = ss(string n.connected);
		VNncompleted =>
			item = ss(string n.taskscomplete);
		VNdisconnecttime =>
			dct := "never";
			if(n.disconnecttime != NOTIME)
				dct = string (now() - n.disconnecttime);
			item = ss(dct);
		VNnfailed =>
			item = ss(string n.tasksfailed);
		VNblacklisted =>
			item = ss(string n.blacklisted);
		VNtimes =>
			item = ss(n.times.name);
		VNattrs =>
			ti: list of ref Sexp;
			for(j := 0; j < len n.attrs.a; j++)
				ti = fmtattr(n.attrs.a[j], fmt[i].fields) :: ti;
			item = sl(ti);
		VNtasks =>
			ti: list of ref Sexp;
			for(tt := n.tasks; tt != nil; tt = tl tt)
				ti = fmttask((hd tt).t1, fmt[i].fields) :: ti;
			item = sl(ti);
		* =>
			logerror(sys->sprint("missing format %d in nodes", fmt[i].kind));
			item = sl(nil);
		}
		f = item :: f;
	}
	return sl(rev(f));
}

fmttask(t: ref Task, fmt: array of Fmt): ref Sexp
{
	f: list of ref Sexp;
	for(i := 0; i < len fmt; i++){
		item: ref Sexp;
		case fmt[i].kind {
		VTjobuniq =>
			item = ss(t.jobuniq);
		VTjobid =>
			item = ss(string t.jobid);
		VTtaskid =>
			item = ss(string t.tgid);
		* =>
			logerror(sys->sprint("missing format %d in nodes.tasks", fmt[i].kind));
			item = sl(nil);
		}
		f = item :: f;
	}
	return sl(rev(f));
}

fmtattr(a: (string, string), fmt: array of Fmt): ref Sexp
{
	f: list of ref Sexp;
	for(i := 0; i < len fmt; i++){
		item: ref Sexp;
		case fmt[i].kind {
		VAattr =>
			item = ss(a.t0);
		VAval =>
			item = ss(a.t1);
		}
		f = item :: f;
	}
	return sl(rev(f));
}

group2str(g: Set): string
{
	exclude := 0;
	if(g.msb()){
		exclude = 1;
		g = g.invert();
	}

	s := "";
	max := g.limit();
	for(i := 0; i < max; i++){
		if(g.holds(i)){
			n := id2node(i);
			# ignore deleted nodes
			if(n != nil)
				s += " " + sys->sprint("%q", n.name);
		}
	}
	if(s == nil){
		if(exclude)
			s = "all";
		else
			s = "none";
	}else{
		if(exclude)
			s = "-" + s;
		else
			s = "+" + s;
	}
	s[len s] = '\n';
	return s;
}

# get id of an arbitrary node, adding a new entry if add!=0
nodeid(name: string, add: int): int
{
	n := allnodes.find(name);
	if(n == nil){
		if(add == 0)
			return -1;
		c := chan of ref Nodeinfo;
		newnodech <-= (name, c);
		n = <-c;
	}
	return n.id;
}

# XXX O(n); could speed up considerably if necessary
id2node(id: int): ref Nodeinfo
{
	for(i := 0; i < len allnodes.items; i++)
		for(nl := allnodes.items[i]; nl != nil; nl = tl nl)
			if((hd nl).t1.id == id)
				return (hd nl).t1;
	return nil;
}

# same as Styxserver.open but replies directly instead,
# to ensure that a flush isn't lost.
open(srv: ref Styxserver, m: ref Tmsg.Open): ref Fid
{
	(c, mode, f, err) := srv.canopen(m);
	if(c == nil){
		styxreply(m, ref Rmsg.Error(m.tag, err));
		return nil;
	}
	c.open(mode, f.qid);
	styxreply(m, ref Rmsg.Open(m.tag, f.qid, srv.iounit()));
	return c;
}

unblacklistproc(interval: int)
{
	period := str2time("5m");
	for(;;){
		sleep(period);

		allnodeslock <-= 1;
		now := epochtime();
		items := allnodes.items;
		set := Sets->None;
		for(i := 0; i < len items; i++){
			for(nl := items[i]; nl != nil; nl = tl nl){
				(nil, n) := hd nl;
				if(n.blacklisted && (now - n.blacklisted) >= interval){
					log(sys->sprint("node autounblacklist %q %q", n.name, n.ipaddr));
					n.blacklisted = 0;
					set = set.add(n.id);
				}
			}
		}
		<-allnodeslock;
		if(!set.eq(Sets->None)){
			fidlock <-= 1;
			globalgroup = globalgroup.X(A|B, set);
			<-fidlock;
			kicktaskmon <-= 1;
		}
	}
}
		
dumpproc(dumpinterval: big)
{
	for(;;){
		if(Debugmem)
			logmemusage();
		sleep(dumpinterval);
		reply := chan of string;
		dumpch <-= reply;
		e := <-reply;
		if(e != nil)
			logerror("autodump failed: "  + e);
	}
}

# dump state to path, making sure that we don't
# erase the old log file before we're sure we've correctly
# written the new one.
dump(path: string): string
{
	a := Archive.new(path + ".new");
	if(a == nil)
		return sys->sprint("cannot create archive %s.new: %r", path);

	c := chan of list of ref Job;
	getjobsch <-= c;
	{
		jl := <-c;
		timeslock <-= 1;
		dump1(jl, a);
		<-timeslock;
	} exception e {
	"error:*" =>
		<-timeslock;
		<-c;
		return e[6:];
	}
	<-c;
	(nil, f) := str->splitr(path, "/");
	sys->remove(path + ".old");
	rename(path, f + ".old");
	if(rename(path + ".new", f) == -1)
		logerror(sys->sprint("rename %q to %q failed: %r", path, f));
	else
		log(sys->sprint("dump %q", path));
	return nil;
}

dump1(q: list of ref Job, a: ref Archive)
{
	a.startsection("globals", array[] of {"nodeid", "globalgroup", "uniqid"});
	a.write(array[] of {string maxnodeid, globalgroup.str(), uniqid});

	a.startsection("times", timesfmt);
	for(i := 0; i < len times.items; i++)
		for(tt := times.items[i]; tt != nil; tt = tl tt){
			(id, nt) := hd tt;
			if(nt.name != "always"){
				a.write(array[] of {
					FMid=>string id,
					FMname=>nt.name,
					FMtext=>nt.text
					}
				);
			}
		}

	a.startsection("nodes", nodefmt);
	for(i = 0; i < len allnodes.items; i++){
		for(nn := allnodes.items[i]; nn != nil; nn = tl nn){
			(nil, n) := hd nn;
			ni := array[] of {
				FNid=>string n.id,
				FNname=>n.name,
				FNipaddr=>n.ipaddr,
				FNdisconnecttime=>nil,
				FNtaskscomplete=>string n.taskscomplete,
				FNtasksfailed=>string n.tasksfailed,
				FNblacklisted=>string n.blacklisted,
				FNattrs=>attrs2string(n.attrs, ' '),
				FNtimes=>string n.times.id,
				};
			# if a node's currently connected, we can assume that it won't be
			# when the dump file is restored from, so assume disconnecttime==now.
			if(n.connected)
				n.disconnecttime = now();
			if(n.disconnecttime == NOTIME)
				ni[FNdisconnecttime] = "never";
			else
				ni[FNdisconnecttime] = string (n.disconnecttime + starttime);

			a.write(ni);
		}
	}

	jobsect := array[len jobfmt + Snumstats] of string;
	jobsect[0:] = jobfmt;
	statsfields := fmtspecs[Qmonitor].fields;
	for(i = 0; i < Snumstats; i++)
		jobsect[i + len jobfmt] = statsfields[i].name;
	a.startsection("jobs", jobsect);
	for(i = 0; i < len jobs.items; i++){
		for(jl := jobs.items[i]; jl != nil; jl = tl jl){
			(nil, j) := hd jl;
			# don't bother archiving jobs which haven't been loaded.
			if(j.argv == nil)
				continue;
			f := array[len jobsect] of string;
			f[FJid] = string j.id;
			f[FJuniq] = j.uniq;
			f[FJargv] = str->quoted(j.argv);
			f[FJprereq] = str->quoted(j.prereqargs);
			f[FJstarttime] = string (j.starttime + starttime);
			f[FJgroup] = j.group.str();
			f[FJmaxtaskuniq] = string j.maxtaskuniq;
			f[FJdone] = string j.done;
			f[FJowner] = j.owner;
			if(j.taskgen != nil)
				f[FJtgstate] = j.taskgen.state();
			(nil, stats) := j.getstats(-1, chan of int);
			if(stats != nil){
				for(k := 0; k < len stats; k++)
					f[k + len jobfmt] = string stats[k];
				a.write(f);
			}
		}
	}
	d := dumpid++;
	a.startsection("tasks", taskfmt);
	for(i = 0; i < len jobs.items; i++){
		for(jl := jobs.items[i]; jl != nil; jl = tl jl){
			(nil, job) := hd jl;
			for(j := 0; j < len job.running.items; j++){
				for(ss := job.running.items[j]; ss != nil; ss = tl ss)
					dumptask(a, (hd ss).t1.task, 1, d);
			}
			for(j = 0; j < len job.disconnected.items; j++){
				for(ss := job.disconnected.items[j]; ss != nil; ss = tl ss)
					dumptask(a, (hd ss).t1, 1, d);
			}
			for(j = 0; j < len job.failed.items; j++){
				for(ss := job.failed.items[j]; ss != nil; ss = tl ss)
					dumptask(a, (hd ss).t1, 0, d);
			}
		}
	}
	a.startsection("queue", array[] of {"jobid"});
	for(; q != nil; q = tl q)
		a.write(array[] of {string (hd q).id});

	a.close();
}

dumptask(a: ref Archive, t: ref Task, disconnected: int, d: int)
{
	if(t.dumped == d)
		return;
	t.dumped = d;
	a.write(array[] of {
		FTjobid=>string t.jobid,
		FTtgid=>t.tgid,
		FTid=>string t.id,
		FTdisconnected=>string disconnected,
		FTtries=>string t.tries,
		FTfailed=>string t.failed,
		}
	);
}

copy(f1, f2: string)
{
	fd1 := sys->open(f1, Sys->OREAD);
	if(fd1 == nil)
		return;
	fd2 := sys->create(f2, Sys->OWRITE, 8r666);
	if(fd2 == nil)
		return;
	buf := array[8192] of byte;
	while((n := sys->read(fd1, buf, len buf)) > 0)
		sys->write(fd2, buf, n);
}

restore(f: string): (ref Jobqueue, string)
{
	log(sys->sprint("dump restore %q", f));
	if(sys->stat(f).t0 == -1 && sys->stat(f + ".old").t0 == -1)
		return (nil, nil);
	a := Unarchive.new(f);
	if(a == nil){
		a = Unarchive.new(f + ".old");
		if(a == nil)
			return (nil, sys->sprint("cannot open %q: %r", f));
		logerror("warning: using old dump file");
	}
	copy(f, f + ".restore" + string (starttime / big 1000));

	{
		return (restore1(a), nil);
	} exception e {
	"parse:*" =>
		# XXX shut down those jobs that have been started
		return (nil, sys->sprint("error reading %q: %s", f, e[6:]));
	}
}

restore1(a: ref Unarchive): ref Jobqueue
{
	a.expectsection("globals", array[] of {"nodeid", "globalgroup", "uniqid"});
	while((d := a.read()) != nil){
		maxnodeid = int d[0];
		globalgroup = sets->str2set(d[1]);
		uniqid = d[2];
	}

	idmap := array[maxnodeid] of {* => -1};

	a.expectsection("times", timesfmt);
	while((d = a.read()) != nil){
		id := int d[FMid];
		(t, err) := timetable->new(d[FMtext]);
		if(t == nil){
			logerror(sys->sprint("cannot restore timetable %q (id %d): %s", d[FMname], id, err));
			continue;
		}
		nt := ref Nodetimes(id, d[FMname], t, 1, d[FMtext]);
		if(times.add(id, nt) == 0)
			logerror(sys->sprint("duplicate times %q (id %d)", d[FMname], id));
		tree.create(big Qtimesdir, dir(Qtimes|(id<<QShift), nt.name, 8r660, "admin", "admin"));
	}

	a.expectsection("nodes", nodefmt);
	maxnodeid = 0;
	while((d = a.read()) != nil){
		id := int d[FNid];
		if(id < 0 || id >= len idmap){
			logerror(sys->sprint("ignoring node with bad id %q", d[FNname]));
			continue;
		}
		nt := times.find(int d[FNtimes]);
		if(nt == nil){
			logerror(sys->sprint("ignoring node with bad times id %d", int d[FNtimes]));
			continue;
		}
		nt.refcount++;
		n := ref Nodeinfo(
			maxnodeid++,
			d[FNname],
			d[FNipaddr],
			0,
			NOTIME,
			int d[FNtaskscomplete],
			int d[FNtasksfailed],
			int d[FNblacklisted],
			string2attrs(d[FNattrs]).t0,		# if they're badly formatted, bad luck
			nil,
			nt				# XXX
		);
		n.times.refcount++;
		if(d[FNdisconnecttime] != "never")
			n.disconnecttime =  big d[FNdisconnecttime] - starttime;

		# XXX backward compatibility - turn boolean into time of day...
		if(n.blacklisted == 1)
			n.blacklisted = epochtime();

		idmap[id] = n.id;
		allnodes.add(n.name, n);
	}
	globalgroup = mapset(globalgroup, idmap);

	jobsect := array[len jobfmt + Snumstats] of string;
	jobsect[0:] = jobfmt;
	statsfields := fmtspecs[Qmonitor].fields;
	for(i := 0; i < Snumstats; i++)
		jobsect[i + len jobfmt] = statsfields[i].name;

	a.expectsection("jobs", jobsect);
	while((d = a.read()) != nil){
		job := Job.new(int d[FJid], d[FJuniq], d[FJowner]);
		if(job == nil){
			logerror(sys->sprint("ignoring job with duplicate id %q", d[FJid]));
			continue;
		}
		job.argv = str->unquoted(d[FJargv]);
		if(job.argv == nil){
			logerror(sys->sprint("ignoring job %q with nil argv", d[FJid]));
			job.decref();
		}
		job.done = int d[FJdone];
		job.prereqargs = str->unquoted(d[FJprereq]);
		if(job.prereqargs != nil){
			(p, err) := loadprereq(job.prereqargs);
			if(p == nil)
				logerror(sys->sprint("bad prereq on job %q: %s", job.idtext(), err));
			job.prereq = p;
		}
		if(job.done)
			job.getstatsch <-= (1, nil);		# set monitor into non-blocking mode.
		else{
			(tg, e) := Taskgen.new(job.idtext(), d[FJtgstate], kicktaskmon, job.argv);
			if(tg == nil){
				logerror(sys->sprint("ignoring job %q; task generator restore failed: %s", job.idtext(), e));
				job.decref();
				continue;
			}
			job.taskgen = tg;
		}
		job.starttime = big d[FJstarttime] - starttime;
		job.group = mapset(sets->str2set(d[FJgroup]), idmap);
		job.maxtaskuniq = int d[FJmaxtaskuniq];
		for(i = len jobfmt; i < len d; i++)
			job.setstat(i - len jobfmt, int d[i]);
		job.setstat(Srunning, 0);
		job.setstat(Sdisconnected, 0);
		if(job.id >= maxjobid)
			maxjobid = job.id + 1;
		log(sys->sprint("unarchive job %q", job.idtext()));
	}

	a.expectsection("tasks", taskfmt);
	while((d = a.read()) != nil){
		job := jobs.find(int d[FTjobid]);
		if(job == nil){
			logerror(sys->sprint("ignoring task %q for non-existent job %q", d[FTid], d[FTjobid]));
			continue;
		}
		task := ref Task(d[FTtgid], int d[FTid], job.id, job.uniq, int d[FTtries], int d[FTfailed], 0, 0, 0, 0, big 0, job.setstatch, chan[1] of int);
		if(int d[FTdisconnected])
			job.disconnected.add(task.id, task);
		else
			job.failed.add(task.id, task);
		log(sys->sprint("unarchived task %q %d", task.about(), int d[FTdisconnected]));
	}

	a.expectsection("queue", array[] of {"jobid"});
	jq: list of ref Job;
	while((d = a.read()) != nil){
		if((job := jobs.find(int d[0])) == nil){
			logerror(sys->sprint("ignoring queue entry %q: job id not found", d[0]));
			continue;
		}
		job.queued = 1;
		jq = job :: jq;
	}
		
	return ref Jobqueue(rev(jq));
}

# map each member, i, of s to its corresponding member idmap[i].
mapset(s: Set, idmap: array of int): Set
{
	m := s.msb() != 0;
	limit := s.limit();
	if(limit > len idmap)
		limit = len idmap;
	r := Sets->None;
	for (i := 0; i < limit; i++)
		if (m == !s.holds(i) && idmap[i] != -1)
			r = r.add(idmap[i]);
	if (m)
		r = r.invert();
	return r;
}

Wait: adt {
	n: ref Node;
	reply: chan of (ref Job, ref Taskinst);
	next, prev: cyclic ref Wait;

	insert: fn(w: self ref Wait, ins: ref Wait);
	remove: fn(w: self ref Wait);
};

Wait.insert(w: self ref Wait, ins: ref Wait)
{
	ins.next = w;
	ins.prev = w.prev;
	ins.prev.next = ins;
	w.prev = ins;
}

Wait.remove(w: self ref Wait)
{
	w.next.prev = w.prev;
	w.prev.next = w.next;
	# make sure ref-counting clears it up immediately:
	w.next = nil;
	w.prev = nil;
}

taskmonproc(q: ref Jobqueue,
	taskreq: chan of (ref Node, chan of (ref Job, ref Taskinst)),
	taskreconnect: chan of (ref Node, string, chan of (ref Job, ref Taskinst, string)),
	taskend: chan of (int, ref Job, ref Taskinst, string),
	getjobs: chan of chan of list of ref Job,
	jobctl: chan of ref Jobctl)
{
	waiting := ref Wait;					# sentinel
	waiting.next = waiting.prev = waiting;
	changed := 0;

	for(;;){
		alt{
		<-taskmonlock =>
			taskmonlock <-= 1;
		<-kicktaskmon =>
			changed = 1;
		(n, reply) := <-taskreq =>
			waiting.insert(ref Wait(n, reply, nil, nil));	# place at the end of the queue.
			changed = 1;
		(n, id, reply) := <-taskreconnect =>
			reply <-= reconnecttask(n, id);
		c := <-getjobs =>
			c <-= q.all();
			c <-= nil;
		c := <-taskflushch =>
			for(w := waiting.next; w != waiting; w = w.next)
				if(w.reply == c){
					w.remove();
					break;
				}
		(status, job, t, err) := <-taskend =>
			taskended(status, job, t, err);
		ctl := <-jobctl =>
			pick c := ctl {
			Start =>
				if(ctl.job.queued == 0){
					q.add(ctl.job);
					ctl.job.starttime = now();
					ctl.job.queued = 1;
					changed = 1;
				}
			Delete =>
				q.del(ctl.job);
				ctl.job.teardown(0);
				ctl.job.queued = 0;
				ctl.job.deleted = 1;
				ctl.job.getstatsch <-= (1, nil);
			Stop =>
				q.del(ctl.job);
				ctl.job.queued = 0;
			Teardown =>
				ctl.job.teardown(c.nongroup);
			Priority =>
				if(ctl.job.queued)
					q.setpriority(c.job, c.justbelow, c.high);
			}
		}
		if(changed == 0)
			continue;

		# if we're being asked for a new task, find one, if poss.
		# for each job in the queue, try and fit the waiting requests to it.
		for(jl := q.all(); jl != nil; jl = tl jl){
			# hand out as many tasks from the current job as possible.
			while(waiting.next != waiting){
				job := hd jl;
				(task, reply, status) := newtask(job, waiting);
				if(task == nil){
					if(status == Nomore){
						log(sys->sprint("job complete %q", job.idtext()));
						job.done = 1;
						sync := chan of int;
						job.incref();
						spawn job.complete(sync);
						<-sync;
						q.del(job);
						job.queued = 0;
					}
					break;
				}
				reply <-= (job, task);
 			}
		}
		changed = 0;
	}
}

statustxt(s: int): string
{
	case s {
	Started =>
		return "started";
	Error =>
		return "error";
	Nomore =>
		return "nomore";
	* =>
		return "unknownstatus";
	}
}

taskended(status: int, job: ref Job, t: ref Taskinst, err: string)
{
	kind, info: string;
	job.lock <-= 1;
	job.running.del(t.id);
	if(job.refcount == 0){
		kind = "redundant-jobdel";
	}else if(job.taskgen == nil){
		t.task.incstat(Srunning, -1);
		t.task.running--;
		kind = "redundant-jobcomplete";
	}else{
		t.task.incstat(Srunning, -1);
		t.task.running--;
		case status {
		Efinished =>
			kind = "redundant-jobgoing";
		Eok =>
			t.task.incstat(Scomplete, +1);
			t.task.incstat(Stotaltime, int ((now() - t.starttime + big 500) / big 1000));
			t.task.done = 1;
			t.node.info.taskscomplete++;
			t.node.info.tasksfailed = 0;
			if(job.disconnected.del(t.task.id))
				t.task.incstat(Sdisconnected, -1);
			kind = "ok";
		Eduplicate =>
			t.task.incstat(Sduplicate, +1);
			kind = "dup";
		Eerror =>
			if(t.stopped){
				kind = "error-stopped";
				info = sys->sprint("%#q", err);
				job.failed.add(t.task.id, t.task);
			}else{
				if(t.task.running == 0 && t.task.done == 0){
					kind = "error";
					# XXX should we add to failed if it's already in disconnected?
					job.failed.add(t.task.id, t.task);
					info = sys->sprint("%#q", err);
					t.task.failed++;
				}else{
					kind = "error-drop";
					info = sys->sprint("%d %d %#q", t.task.running, t.task.done, err);
				}
				t.node.info.tasksfailed++;
			}
		Edisconnect =>
			if(t.task.done == 0){
				if(job.disconnected.add(t.task.id, t.task))
					t.task.incstat(Sdisconnected, +1);
				kind = "disconnect";
			}else
				kind = "disconnect-completed";
			t.node.info.tasksfailed++;
		* =>
			kind = "greg";
		}
		if(t.node.info.tasksfailed > Maxnodefailures){
			fidlock <-= 1;
			if(t.node.info.blacklisted == 0){
				globalgroup = globalgroup.del(t.node.info.id);
				t.node.info.blacklisted = epochtime();
				t.node.info.tasksfailed = 0;
				log(sys->sprint("node blacklist %q %q", t.node.info.name, t.node.ipaddr));
			}
			<-fidlock;
		}
	}
	<-job.lock;
	log(sys->sprint("task end %s %q %q %q %bd %s", kind, t.node.info.name, t.node.ipaddr, t.task.about(), now() - t.starttime, info));
	t.node.info.deltask(t.task);
}

reconnecttask(n: ref Node, id: string): (ref Job, ref Taskinst, string)
{
	(jobid, jobuniq, taskuniq) := parsetaskid(id);
	if(jobid == -1)
		return (nil, nil, "bad task id");
	job := jobs.find(jobid);
	if(job == nil || job.uniq != jobuniq){
		err := "no matching job";
		if(job != nil)
			err = "job unique id does not match";
		return (nil, nil, err);
	}
	if(job.done)
		return (nil, nil, "job has completed");

	task := job.disconnected.find(taskuniq);
	if(task != nil){
		if(task.done)
			return (nil, nil, "task has completed");	# XXX delete from disconnected?
	}else{
		# if not found amongst disconnected tasks, try currently "active" tasks;
		# the connection might have failed to go away for some reason.
		items := job.running.items;
	Find:
		for(i := 0; i < len items; i++){
			for(tt := items[i]; tt != nil; tt = tl tt){
				(nil, t) := hd tt;
				if(t.task.id == taskuniq){
					task = t.task;
					break Find;
				}
			}
		}
		if(task == nil)
			return (nil, nil, "task not found");
	}
	t := Taskinst.new(task);
	# XXX should task generator be given details of the client that's
	# attempting to reconnect?
	(status, err) := job.taskgen.reconnect(task.tgid, t.read, t.write, t.finish);
	if(status != Started)
		return (nil, nil, err);

	t.id = job.maxtaskuniq++;
	t.node = n;
	n.info.addtask(task, n.ipaddr);

	task.incstat(Srunning, +1);
	if(job.disconnected.del(taskuniq))
		task.incstat(Sdisconnected, -1);
	task.running++;
	t.starttime = now();
	task.laststarttime = t.starttime;
	job.running.add(t.id, t);
	return (job, t, nil);
}

# start a task going for job.
# return (task, reply, status)
# where task is the task to run, reply is the reply channel from
# the waiting list that has been chosen, and status is
# one of Started (job started), Error (no appropriate clients waiting),
# or Nomore (no more tasks for this job).
newtask(job: ref Job, waiting: ref Wait): (ref Taskinst, chan of (ref Job, ref Taskinst), int)
{
	# try to restart a failed task
	items := job.failed.items;
	for(i := 0; i < len items; i++){
		for(tt := items[i]; tt != nil; tt = tl tt){
			(nil, task) := hd tt;
			# XXX should do something here so that we don't start a task
			# immediately on a node that's just failed it
			(t, status, reply) := starttask(job, task, waiting);
			case status {
			Nomore =>
				# mark it complete so it won't be restarted
				task.done = 1;
				task.incstat(Sfailed, +1);
				task.incstat(Scomplete, +1);
				log(sys->sprint("task nomore %q", task.about()));
				# delete during traverse relies on implementation of Table.
				job.failed.del(task.id);
			Error =>
				# transient error; leave in failed table
				;
			Started =>
				job.failed.del(task.id);
				return (t, reply, Started);
			}
		}
	}

	# if not, try to start a new task
	task := ref Task(nil, -1, job.id, job.uniq, 0, 0, 0, 0, 0, 0, big 0, job.setstatch, chan[1] of int);
	(t, status, reply) := starttask(job, task, waiting);
	if(status == Started)
		return (t, reply, Started);

	if(status != Nomore)
		return (nil, nil, Error);

	# if not, try to restart a slow task
	return restartslowtask(job, waiting);
}

restartslowtask(job: ref Job, waiting: ref Wait): (ref Taskinst, chan of (ref Job, ref Taskinst), int)
{
	# of those tasks that have the least number of current nodes
	# running them, search for the one that has been running for the
	# longest time.
	tasks: list of ref Task;
	for(i := 0; i < len job.disconnected.items; i++)
		for(ss := job.disconnected.items[i]; ss != nil; ss = tl ss)
			if((hd ss).t1.done == 0)
				tasks = (hd ss).t1 :: tasks;

	ndisconnected := 0;
	if(Verbose)
		ndisconnected = len tasks;
	for(i = 0; i < len job.running.items; i++){
		for(tt := job.running.items[i]; tt != nil; tt = tl tt){
			(nil, t) := hd tt;
			if(t.task.done == 0)
				tasks = t.task :: tasks;
		}
	}
	a := array[len tasks] of ref Task;
	for(i = 0; tasks != nil; tasks = tl tasks)
		a[i++] = hd tasks;
	mergesort(a, array[len a] of ref Task);

	# now go through until we can start one successfully.
	remaining := len a;
	prev := -1;
	for(i = 0; i < len a; i++){
		task := a[i];
		if(task.id == prev)
			continue;		# ignore duplicates
		(t, status, reply) := starttask(job, task, waiting);
		case status {
		Started =>
			return (t, reply, Started);
		Nomore =>
			task.done = 1;
			task.incstat(Sfailed, +1);
			task.incstat(Scomplete, +1);
			remaining--;
		}
		prev = task.id;
	}
	if(remaining == 0)
		return (nil, nil, Nomore);
	return (nil, nil, Error);
}

greater(a, b: ref Task): int
{
	if(a.running < b.running)
		return 0;
	if(a.running == b.running)
		return a.laststarttime > b.laststarttime;
	return 1;
}

mergesort(a, b: array of ref Task)
{
	r := len a;
	if (r > 1) {
		m := (r-1)/2 + 1;
		mergesort(a[0:m], b[0:m]);
		mergesort(a[m:], b[m:]);
		b[0:] = a;
		for ((i, j, k) := (0, m, 0); i < m && j < r; k++) {
			if (greater(b[i], b[j]))
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

starttask(job: ref Job, task: ref Task, waiting: ref Wait): (ref Taskinst, int, chan of (ref Job, ref Taskinst))
{
	if(job.nomore && task.tgid == nil)
		return (nil, Nomore, nil);
	t := Taskinst.new(task);

	currtime := epochtime();
	for(w := waiting.next; w != waiting; w = w.next){
		(n, reply) := (w.n, w.reply);
		if(job.group.X(A&B, globalgroup).holds(n.info.id) == 0)
			continue;
		# don't hand out the same task twice to the same node in a row.
		if(n.lasttask == task.idtext()){
			log(sys->sprint("task nottwice %q %q %q", n.info.name, n.ipaddr, task.about()));
			continue;
		}
		(in, time) := n.info.times.get(currtime);
		if(in == 0 || time - currtime < 3)
			continue;
		spec := ref Taskgenerator->Clientspec(n.info.name, n.user, n.info.attrs);
		if(job.prereq != nil && job.prereq->ok(spec) == 0)
			continue;
		(status, tgid) := job.taskgen.start(task.tgid, time-currtime, task.failed, spec, t.read, t.write, t.finish);
		case status {
		Started =>
			t.id = job.maxtaskuniq++;
			# XXX could check that tgid contains no newlines.
			if(task.tgid == nil){
				task.tgid = tgid;
				task.id = t.id;
				log(sys->sprint("task new %q %q %q %d", n.info.name, n.ipaddr, t.task.about(), time-currtime));
			}else
				log(sys->sprint("task restart %q %q %q %d", n.info.name, n.ipaddr, t.task.about(), time-currtime));
			task.tries++;
			t.node = n;
			t.node.info.addtask(t.task, t.node.ipaddr);
			task.incstat(Srunning, +1);
			task.running++;
			task.laststarttime = t.starttime = now();
			job.running.add(t.id, t);
			w.remove();
			return (t, status, reply);
		Nomore =>
			if(task.tgid == nil){
				log(sys->sprint("job nomore %q %#q", job.idtext(), tgid));
				job.nomore = 1;
			}else
				log(sys->sprint("task nomore %q %#q", task.about(), tgid));
			return (nil, status, nil);
		Error =>
			if(Verbose)
				log(sys->sprint("task notstarted %q %q %q %#q", n.info.name, n.ipaddr, task.about(), tgid));
			;	# continue to try and find a more appropriate waiting client.
		}
	}
	return (nil, Error, nil);
}

ticker(tick: chan of int)
{
	for(;;){
		sys->sleep(1000);
		tick <-= 1;
	}
}

# remind taskmon when it should reevaluate tasks to see
# if any are now eligible that were not.
timepromptproc(timeschangedch, kick: chan of int)
{
	deadline := 16r7fffffff;
	spawn ticker(tick := chan of int);
	reeval := 0;
	for(;;){
		alt{
		<-tick =>
			if(epochtime() >= deadline)
				reeval = 1;
		<-timeschangedch =>
			reeval = 1;
		}
		if(reeval){
			kick <-= 1;
			now := epochtime();
			deadline = 16r7fffffff;
			timeslock <-= 1;
			for(i := 0; i < len times.items; i++){
				for(tt := times.items[i]; tt != nil; tt = tl tt){
					(nil, t) := hd tt;
					(nil, time) := t.get(now);
					if(time < deadline)
						deadline = time;
				}
			}
			<-timeslock;
			reeval = 0;
		}
	}
}			

stoptask(n: ref Node, clientid: string)
{
	if(active := <-n.active)
		n.stoptask <-= clientid;
	n.active <-= active;
}

Taskinst.stop(t: self ref Taskinst)
{
	if(t.node == nil)
		return;
	t.stopped = 1;
	# don't send a stop message before the client has written its
	# id - there's no point. they'll get an error when they try to
	# do that anyway.
	if(t.clientid != nil)
		stoptask(t.node, t.clientid);
}

Task.idtext(t: self ref Task): string
{
	return sys->sprint("%s.%d#%d", t.jobuniq, t.jobid, t.id);
}

Task.about(t: self ref Task): string
{
	return sys->sprint("%s.%d#%d:%q", t.jobuniq, t.jobid, t.id, t.tgid);
}

Taskinst.new(task: ref Task): ref Taskinst
{
	return ref Taskinst(
		-1,
		task,
		chan of Readreq,
		chan of Writereq,
		chan of Finishreq,
		now(),
		nil,
		nil,
		0
	);
}

Task.setstat(task: self ref Task, what: int, v: int)
{
	task.setstatch <-= (what, Setval, v);
}

Task.incstat(task: self ref Task, what: int, v: int)
{
	task.setstatch <-= (what, Incval, v);
}

Nodeinfo.addtask(n: self ref Nodeinfo, t: ref Task, ip: string)
{
	allnodeslock <-= 1;
	n.tasks = (ip, t) :: n.tasks;
	<-allnodeslock;
}

Nodeinfo.delipaddr(n: self ref Nodeinfo, ip: string)
{
	allnodeslock <-= 1;
	# remove task from those the node is recorded as processing.
	nt: list of (string, ref Task);
	for(tt := n.tasks; tt != nil; tt = tl tt)
		if((hd tt).t0 != ip)
			nt = hd tt :: nt;
	n.tasks = nt;
	<-allnodeslock;
}

Nodeinfo.deltask(n: self ref Nodeinfo, t: ref Task)
{
	allnodeslock <-= 1;
	# remove task from those the node is recorded as processing.
	nt: list of (string, ref Task);
	for(tt := n.tasks; tt != nil; tt = tl tt){
		if((hd tt).t1 == t){
			nt = joinsp(tl tt, nt);
			break;
		}
		nt = hd tt :: nt;
	}
	n.tasks = nt;
	<-allnodeslock;
}


Job.new(id: int, uniq: string, user: string): ref Job
{
	if(id == -1){
		id = maxjobid++;
		uniq = uniqid;
	}else if(jobs.find(id) != nil)
		return nil;
	j := ref Job(
		id,
		uniq,
		nil,
		1,
		nil,
		nil,
		nil,
		# XXX tune these numbers
		Table[ref Task].new(7, nil),
		Table[ref Task].new(7, nil),
		Table[ref Taskinst].new(7, nil),
		chan of (int, int, int),
		chan of (int, chan of (int, array of int)),
		big -1,
		chan[1] of int,
		Sets->All,
		0,
		1,
		0,
		0,
		0,
		nil,
		user
	);
	pp := Qjobdir | (j.id << QShift);
	tree.create(big Qadmindir, dir(pp, string j.id, 8r550 | Sys->DMDIR, user, "admin"));
	tree.create(big pp, dir(Qjobctl | (j.id<<QShift), "ctl", 8r660, user, "admin"));
	tree.create(big pp, dir(Qmonitor | (j.id<<QShift), "monitor", 8r660, user, "admin"));
	tree.create(big pp, dir(Qduration | (j.id<<QShift), "duration", 8r440, user, "admin"));
	tree.create(big pp, dir(Qlog | (j.id<<QShift), "log", 8r440, user, "admin"));
	tree.create(big pp, dir(Qjobgroup | (j.id<<QShift), "group", 8r440, user, "admin"));
	tree.create(big pp, dir(Qjobdata | (j.id<<QShift), "data", 8r660, user, "admin"));
	tree.create(big pp, dir(Qjobdescription | (j.id<<QShift), "description", 8r660, user, "admin"));
	tree.create(big pp, dir(Qjobid | (j.id<<QShift), "id", 8r440, user, "admin"));
	tree.create(big pp, dir(Qjobnodes | (j.id<<QShift), "nodes", 8r440, user, "admin"));
	jobs.add(j.id, j);
	spawn statsproc(j.setstatch, j.getstatsch);
	log(sys->sprint("job new %q", j.idtext()));
	return j;
}

Job.complete(job: self ref Job, sync: chan of int)
{
	del: list of ref Taskinst;
	for(i := 0; i < len job.running.items; i++)
		for(tt := job.running.items[i]; tt != nil; tt = tl tt){
			(nil, t) := hd tt;
			if(t.task.jobid == job.id)
				del = t :: del;
		}
	sync <-= 1;
	for(; del != nil; del = tl del){
		t := hd del;
		t.task.lock <-= 1;
		if(t.task.jobid == job.id && t.finish != nil){
			reply := chan of string;
			t.stop();
			t.finish <-= (0, now() - t.starttime, reply);
			<-reply;
			t.finish = nil;
			t.read = nil;
			t.write = nil;
		}
		if(t.node != nil)
			t.node.info.deltask(t.task);
		<-t.task.lock;
	}
	job.lock <-= 1;
	if(job.taskgen != nil)
		job.taskgen.complete();
	<-job.lock;
	job.getstatsch <-= (1, nil);		# set monitor into non-blocking mode.
	job.decref();
}

# stop tasks in a job; if nongroup!=0, stop only tasks
# on nodes that are not in the job's current group.
Job.teardown(job: self ref Job, nongroup: int)
{
	items := job.running.items;
	for(i := 0; i < len items; i++){
		for(tt := items[i]; tt != nil; tt = tl tt){
			(nil, t) := hd tt;
			if(t != nil && t.task.jobid == job.id)
			if(!nongroup || job.group.X(A&B, globalgroup).holds(t.node.info.id) == 0)
				t.stop();
		}
	}
}

Job.idtext(job: self ref Job): string
{
	return sys->sprint("%s.%d", job.uniq, job.id);
}

Job.incref(job: self ref Job): int
{
	job.lock <-= 1;
	r := job.refcount;
	if(r > 0)
		job.refcount = ++r;
	<-job.lock;
	return r;
}

Job.decref(job: self ref Job)
{
	job.lock <-= 1;
	if(--job.refcount == 0){
		log(sys->sprint("job delete %q", job.idtext()));
		jobs.del(job.id);
		tree.remove(big (Qjobdir | (job.id << QShift)));
		job.getstatsch <-= (0, nil);
		job.getstatsch = nil;
		if(job.taskgen != nil){
			job.taskgen.quit();
			job.taskgen = nil;
		}
		spawn remove(root+"/work/"+job.idtext());	# could take ages, so don't wait for it.
	}
	<-job.lock;
}

Job.setstat(j: self ref Job, what, v: int)
{
	j.setstatch <-= (what, Setval, v);
}

Job.getstats(job: self ref Job, version: int, flushc: chan of int): (int, array of int)
{
	job.lock <-= 1;	
	if(job.getstatsch == nil){
		<-job.lock;
		return (0, nil);
	}
	c := chan[1] of (int, array of int);
	job.getstatsch <-= (version, c);
	<-job.lock;
	alt{
	r := <-c =>
		return r;
	<-flushc =>
		return (-1, nil);
	}
}

statsproc(setstat: chan of (int, int, int), getstat: chan of (int, chan of (int, array of int)))
{
	waiting: list of chan of (int, array of int);
	stats := array[Snumstats] of {* => 0};
	version := 1;
	blocking := 1;
Loop:
	for(;;) alt {
	(stat, how, v) := <-setstat =>
		version++;
		case how {
		Incval =>
			stats[stat] += v;
		Setval =>
			stats[stat] = v;
		}
		if(waiting != nil){
			ns := (array[len stats] of int)[0:] = stats;
			for(; waiting != nil; waiting = tl waiting)
				hd waiting <-= (version, ns);
		}
	(vers, c) := <-getstat =>
		if(c == nil){
			if(vers){
				blocking = 0;
				for(; waiting != nil; waiting = tl waiting)
					hd waiting <-= (0, nil);
				break;
			}
			break Loop;
		}
		if(vers < version){
			ns := (array[len stats] of int)[0:] = stats;
			c <-= (version, ns);
		}else if(blocking)
			waiting = c :: waiting;
		else
			c <-= (0, nil);
	}
	for(; waiting != nil; waiting = tl waiting)
		hd waiting <-= (0, nil);
}

Taskgen.new(uniq: string, state: string, kick: chan of int, args: list of string): (ref Taskgen, string)
{
	if(args == nil)
		return (nil, "no module specified");
	p := hd args;
	for(i := 0; i < len p; i++)
		if(p[i] == '/')
			return (nil, "illegal module name");
	p = taskgenpath + "/" + p + "gen.dis";
	mod := load Taskgenerator p;
	if(mod == nil)
		return (nil, sys->sprint("cannot load %q: %r", p));
	workdir := root+"/work/"+uniq;
	if(state == nil){
		if(sys->create(workdir, Sys->OREAD, Sys->DMDIR|8r777) == nil){
			d := Sys->nulldir;
			d.name = "Old"+uniq;
			sys->wstat(workdir, d);
			if(sys->create(workdir, Sys->OREAD, Sys->DMDIR|8r777) == nil)
				return (nil, sys->sprint("cannot create workdir %q: %r", workdir));
		}
	}
	r := chan of (chan of ref Taskgenreq, string);
	spawn taskgenproc(mod, uniq, workdir, state, args, kick, r);
	(reqch, e) := <-r;
	if(e != nil)
		return (nil, e);
	if(reqch == nil)
		return (nil, "no request channel");
	return (ref Taskgen(reqch), nil);
}

Taskgen.taskcount(t: self ref Taskgen): int
{
	reply := chan of int;
	t.req <-= ref Taskgenreq.Taskcount(reply);
	return <-reply;
}

Taskgen.state(t: self ref Taskgen): string
{
	reply := chan of string;
	t.req <-= ref Taskgenreq.State(reply);
	return <-reply;
}

Taskgen.opendata(t: self ref Taskgen,
		user: string,
		mode: int,
		read:		chan of Readreq,
		write:	chan of Writereq,
		clunk:	chan of int): string
{
	reply := chan of string;
	t.req <-= ref Taskgenreq.Opendata(user, mode, read, write, clunk, reply);
	return <-reply;
}

Taskgen.start(t: self ref Taskgen,
		id: string,
		duration: int,
		failed:	int,
		spec: ref Clientspec,
		read: chan of Readreq,
		write: chan of Writereq,
		finish: chan of Finishreq): (int, string)
{
	reply := chan of (int, string);
	t.req <-= ref Taskgenreq.Start(id, duration, failed, spec, read, write, finish, reply);
	(status, s) := <-reply;
	if(status == Started && id == nil && s == nil){
		log("task start-badid");
		(status, s) = (Nomore, "bad id");
	}
	return (status, s);
}

Taskgen.reconnect(t: self ref Taskgen, id: string,
		read: chan of Readreq,
		write: chan of Writereq,
		finish: chan of Finishreq): (int, string)
{
	reply := chan of (int, string);
	t.req <-= ref Taskgenreq.Reconnect(id, read, write, finish, reply);
	return <-reply;
}

Taskgen.complete(t: self ref Taskgen)
{
	t.req <-= ref Taskgenreq.Complete();
}

Taskgen.quit(t: self ref Taskgen)
{
	t.req <-= nil;
}

Nodetimes.get(n: self ref Nodetimes, t: int): (int, int)
{
	# could cache last value, but must guard against race if so.
	return n.t.get(t);
}

tasklogproc(jobid: string, workdir: string, fd: ref Sys->FD, sync: chan of int)
{
	sys->pctl(Sys->NEWFD, fd.fd :: nil);
	tfd := sys->open("/dev/time", Sys->OREAD);
	if((logfd := sys->open(workdir+"/log", Sys->OWRITE)) != nil)
		sys->seek(logfd, big 0, Sys->SEEKEND);
	else if((logfd = sys->create(workdir+"/log", Sys->OWRITE, 8r666)) == nil)
		log("job nolog "+jobid);

	tstarttime := fnow(tfd);
	sys->fprint(logfd, "%.10bd starttime %.10bd\n", big 0, tstarttime+starttime);

	fd = sys->fildes(fd.fd);
	sync <-= 1;
	iob := bufio->fopen(fd, Sys->OREAD);
	fd = nil;
	prefix := "job report " + jobid + " ";
	while((s := iob.gets('\n')) != nil){
		log(prefix + s[0:len s - 1]);
		sys->fprint(logfd, "%.10bd %s", fnow(tfd)-tstarttime, s);
	}
	log("job clean " + jobid);
}

taskgenproc(mod: Taskgenerator, uniq, workdir, state: string, args: list of string, kick: chan of int,
		r: chan of (chan of ref Taskgenreq, string))
{
	sys->pctl(Sys->NEWFD | Sys->FORKNS | Sys->FORKENV, 0::1::2::nil);
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	lsync := chan of int;
	spawn tasklogproc(uniq, workdir, p[0], lsync);
	<-lsync;
	sys->dup(p[1].fd, 2);
	sys->dup(p[1].fd, 1);
	p = nil;
	if(sys->chdir(workdir) ==-1){
		r <-= (nil, sys->sprint("cannot cd to %q: %r", workdir));
		exit;
	}
	{
		r <-= mod->init(root, workdir, state, kick, args);
	}exception e {
	"fail:*" =>
		r <-= (nil, e[5:]);
	}
}

getfid(fid: ref Fid): ref Sfid
{
	fidlock <-= 1;
	for(ff := fids[fid.fid % len fids]; ff != nil; ff = tl ff)
		if((hd ff).fid == fid.fid){
			<-fidlock;
			return hd ff;
		}
	<-fidlock;
	return nil;
}

newfid(fid: ref Fid): ref Sfid
{
	fidlock <-= 1;
	f := ref Sfid(fid.fid, nil, Tstartstate, nil, 0, big 0, nil, nil, nil, nil, nil);
	slot := fid.fid % len fids;
	fids[slot] = f :: fids[slot];
	<-fidlock;
	return f;
}

delfid(sfid: ref Sfid)
{
	fidlock <-= 1;
	nff: list of ref Sfid;
	slot := sfid.fid % len fids;
	for(ff := fids[slot]; ff != nil; ff = tl ff)
		if((hd ff).fid != sfid.fid)
			nff = hd ff :: nff;
	fids[slot ] = nff;
	<-fidlock;
}

Jobqueue.add(q: self ref Jobqueue, j: ref Job)
{
	q.jobs = rev(j :: rev(q.jobs));
}

Jobqueue.del(q: self ref Jobqueue, j: ref Job)
{
	jl: list of ref Job;
	for(; q.jobs != nil; q.jobs = tl q.jobs)
		if(hd q.jobs != j)
			jl = hd q.jobs :: jl;
	q.jobs = rev(jl);
}

Jobqueue.get(q: self ref Jobqueue): ref Job
{
	if(q.jobs == nil)
		return nil;
	j := hd q.jobs;
	q.jobs = tl q.jobs;
	return j;
}

Jobqueue.peek(q: self ref Jobqueue): ref Job
{
	if(q.jobs == nil)
		return nil;
	return hd q.jobs;
}

Jobqueue.all(q: self ref Jobqueue): list of ref Job
{
	return q.jobs;
}

# set a job's priority. if justbelow!=nil, set pri just below that job,
# otherwise place the job at the top (high!=0) or bottom of the queue.
Jobqueue.setpriority(q: self ref Jobqueue, j: ref Job, justbelow: ref Job, high: int)
{
	jl: list of ref Job;
	found := 0;
	for(; q.jobs != nil; q.jobs = tl q.jobs){
		k := hd q.jobs;
		if(k != j)
			jl = k :: jl;
		if(k == justbelow){
			jl = j :: jl;
			found = 1;
		}
	}
	if(found == 0 && !high)
		jl = j :: jl;
	q.jobs = rev(jl);
	if(found == 0 && high)
		q.jobs = j :: q.jobs;
}

Jobqueue.isempty(q: self ref Jobqueue): int
{
	return q.jobs == nil;
}

string2attrs(s: string): (Attrs[string], string)
{
	attrs: Attrs[string];
	toks := str->unquoted(s);
	if(len toks % 2 != 0)
		return (attrs, "unbalanced set of attributes");
	if(toks == nil)
		return (attrs, "no attributes found");
	for(; toks != nil; toks = tl tl toks){
		(a, v) := (hd toks, hd tl toks);
		for(i := 0; i < len a; i++)
			if(a[i] == '\n')
				a[i] = ' ';
		for(i = 0; i < len v; i++)
			if(v[i] == '\n')
				v[i] = ' ';
		attrs = attrs.add(a, v);
	}
	return (attrs, nil);
}

attrs2string(attrs: Attrs[string], sep: int): string
{
	s := "";
	for(i := 0; i < len attrs.a; i++)
		s += sys->sprint("%q %q%c", attrs.a[i].t0, attrs.a[i].t1, sep);
	return s;
}

fidnode(fid: ref Fid): ref Node
{
	return nodes.find(fid.session.handle);
}

dir(path: int, name: string, perm: int, owner, group: string): Sys->Dir
{
	d := sys->zerodir;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.name = name;
	d.uid = owner;
	d.gid = group;
	d.mode = perm;
	d.mtime = d.atime = int ((now() + starttime) / big 1000);
	return d;
}

qid(path: int): Sys->Qid
{
	return dir(path, nil, 0, nil, nil).qid;
}

Table[T].new(nslots: int, nilval: T): ref Table[T]
{
	if(nslots == 0)
		nslots = 13;
	return ref Table[T](array[nslots] of list of (int, T), nilval);
}

Table[T].add(t: self ref Table[T], id: int, x: T): int
{
	slot := id % len t.items;
	for(q := t.items[slot]; q != nil; q = tl q)
		if((hd q).t0 == id)
			return 0;
	t.items[slot] = (id, x) :: t.items[slot];
	return 1;
}

Table[T].del(t: self ref Table[T], id: int): int
{
	slot := id % len t.items;
	
	p: list of (int, T);
	r := 0;
	for(q := t.items[slot]; q != nil; q = tl q){
		if((hd q).t0 == id){
			p = joinip(p, tl q);
			r = 1;
			break;
		}
		p = hd q :: p;
	}
	t.items[slot] = p;
	return r;
}

Table[T].find(t: self ref Table[T], id: int): T
{
	for(p := t.items[id % len t.items]; p != nil; p = tl p)
		if((hd p).t0 == id)
			return (hd p).t1;
	return t.nilval;
}

hashfn(s: string, n: int): int
{
	h := 0;
	m := len s;
	for(i:=0; i<m; i++){
		h = 65599*h+s[i];
	}
	return (h & 16r7fffffff) % n;
}

Strhash[T].new(nslots: int, nilval: T): ref Strhash[T]
{
	if(nslots == 0)
		nslots = 13;
	return ref Strhash[T](array[nslots] of list of (string, T), nilval);
}

Strhash[T].add(t: self ref Strhash, id: string, x: T)
{
	slot := hashfn(id, len t.items);
	t.items[slot] = (id, x) :: t.items[slot];
}

Strhash[T].del(t: self ref Strhash, id: string)
{
	slot := hashfn(id, len t.items);

	p: list of (string, T);
	for(q := t.items[slot]; q != nil; q = tl q)
		if((hd q).t0 != id)
			p = hd q :: p;
	t.items[slot] = p;
}

Strhash[T].find(t: self ref Strhash, id: string): T
{
	for(p := t.items[hashfn(id, len t.items)]; p != nil; p = tl p)
		if((hd p).t0 == id)
			return (hd p).t1;
	return t.nilval;
}

rev[T](x: list of T): list of T
{
	l: list of T;
	for(; x != nil; x = tl x)
		l = hd x :: l;
	return l;
}

# join x to y, leaving result in arbitrary order.
join[T](x, y: list of T): list of T
{
	if(len x > len y)
		(x, y) = (y, x);
	for(; x != nil; x = tl x)
		y = hd x :: y;
	return y;
}

# join x to y, leaving result in arbitrary order.
joinip[T](x, y: list of (int, T)): list of (int, T)
{
	if(len x > len y)
		(x, y) = (y, x);
	for(; x != nil; x = tl x)
		y = hd x :: y;
	return y;
}

joinsp[T](x, y: list of (string, T)): list of (string, T)
{
	if(len x > len y)
		(x, y) = (y, x);
	for(; x != nil; x = tl x)
		y = hd x :: y;
	return y;
}


hostname(addr: string): string
{
	(nil, toks) := sys->tokenize(addr, "!");
	if(len toks != 2)
		return addr;
	addr = hd toks;
	if(NoDNS)
		return addr;
	a := addr2arpa(addr);
	if(a == nil)
		return addr;
	fd := sys->open("/net/dns", Sys->ORDWR);
	if(fd == nil)
		return addr;
	if(sys->fprint(fd, "%s ptr", a) < 0){
		err := sys->sprint("%r");
		log(sys->sprint("dnslookup failed %q %q", addr, err));
		return addr;
	}
	buf := array[1024] of byte;
	sys->seek(fd, big 0, 0);
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return addr;
	a = string buf[0:n];
	for(i := 0; i < len a; i++)
		if(a[i] == '\t')
			break;
	if(i == len a)
		return addr;
	i++;
	# return address of the form:
	# 68.1.1.200.in-addr.arpa ptr	presto.vitanuova.com(0)
	for(j := len a - 1; j > i; j--)
		if(a[j] == '(')
			return a[i:j];
	return a[i:];
}

addr2arpa(a: string): string
{
	addr := "in-addr.arpa";
	for(toks := sys->tokenize(a, ".").t1; toks != nil; toks = tl toks)
		addr = hd toks + "." + addr;
	return addr;
}

bufferproc[T](in, out: chan of T, stop: chan of int)
{
	sys->pctl(Sys->NEWFD, nil);
	h, t: list of T;
	dummyout := chan of T;
	for(;;){
		outc := dummyout;
		s: T;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		<-stop =>
			return;
		}
	}
}

# time in milliseconds since scheduler was started
now(): big
{
	return fnow(timefd);
}

fnow(tfd: ref Sys->FD): big
{
	buf := array[24] of byte;
	n := sys->pread(tfd, buf, len buf, big 0);
	if(n <= 0)
		return big 0;
	return big string buf[0:n] / big 1000 - starttime;
}

epochtime(): int
{
	buf := array[24] of byte;
	n := sys->pread(timefd, buf, len buf, big 0);
	if(n <= 0)
		return 0;
	return int (big string buf[0:n] / big 1000000);
}

maxbasename(path: string): int
{
	(d, nil) := str->splitr(path, "/");
	if(d == nil)
		d = ".";
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil){
		logerror(sys->sprint("cannot open %q: %r", d));
		return -1;
	}
	max := -1;
	while(((nil, dd) := sys->dirread(fd)).t0 > 0){
		for(i := 0; i < len dd; i++){
			name := dd[i].name;
			if(len name > len path && name[0:len path] == path){
				x := int name[len path:];
				if(x > max)
					max = x;
			}
		}
	}
	return max;
}

logfileproc(loginterval: big, log: string, sync: chan of int)
{
	if(log == nil)
		log = root + "/log";
	else
		log = relpath(log, root);
	(ok, stat) := sys->stat(log);
	if(ok == -1){
		if(log != nil){
			logerror(sys->sprint("cannot stat %s: %r", log));
			sync <-= -1;
		}else
			sync <-= 0;
		exit;
	}
	# if log file is a regular file, then don't do log-file rollover
	if((stat.mode & Sys->DMDIR) == 0){
		fd := sys->open(log, Sys->OWRITE);
		if(fd == nil){
			logerror(sys->sprint("cannot open %s: %r", log));
			sync <-= -1;
			exit;
		}
		sys->seek(fd, big 0, Sys->SEEKEND);
		logch = chan of string;
		spawn logproc(fd);
		sync <-= 0;
		exit;
	}
	for(;;){
		logf := log + "/log." + string ((now() + starttime) / big 1000);
		fd := sys->create(logf, Sys->OWRITE, 8r666);		# XXX |Sys->DMAPPEND?
		if(fd == nil){
			logerror(sys->sprint("cannot create %s: %r", logf));
			if(sync != nil)
				sync <-= -1;
			exit;
		}
		if(sync != nil){
			sync <-= 0;
			sync = nil;
			logch = chan of string;
		}else
			logch <-= nil;
		spawn logproc(fd);
		sleep(loginterval);
	}
}

# make sure log writes are serialised.
# XXX does each write need to be synchronous?
logproc(logfd: ref Sys->FD)
{
	sys->fprint(logfd, "%.10bd starttime %.10bd\n", now(), starttime);
	while((s := <-logch) != nil)
		sys->fprint(logfd, "%.10bd %s\n", now(), s);
}

# XXX should we log the time of day too?
log(s: string)
{
	if(logch != nil)
		logch <-= s;
}

logerror(s: string)
{
	sys->fprint(stderr(), "scheduler: %s\n", s);
	if(logch != nil)
		logch <-= sys->sprint("error %q", s);
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

rename(f1, name: string): int
{
	d := Sys->nulldir;
	d.name = name;
	return sys->wstat(f1, d);
}

remove(path: string)
{
	(ok, stat) := sys->stat(path);
	if(ok == -1)
		return;
	remove0(path, stat.mode & Sys->DMDIR);
}

remove0(path: string, isdir: int): int
{
	if(isdir == 0){
		if(sys->remove(path) == -1){
			logerror(sys->sprint("cannot remove %q: %r", path));
			return -1;
		}
		return 0;
	}
	(d, n) := readdir->init(path, Readdir->NONE|Readdir->COMPACT);
	r := 0;
	for(i := 0; i < n; i++)
		if(remove0(path + "/" + d[i].name, d[i].mode & Sys->DMDIR) == -1)
			r = -1;
	if(r == -1){
		# if we've had an error, try again anyway in case someone else removed it.
		sys->remove(path);
	}else if (sys->remove(path) == -1){
		logerror(sys->sprint("cannot remove %q: %r", path));
		r = -1;
	}
	return r;
}

relpath(p: string, d: string): string
{
	if(p != nil && p[0] == '/' || len p > 1 && p[0] == '.' && p[1] == '/')
		return p;
	return d+"/"+p;
}

cleanstr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			break;
	if(i == len s)
		return s;
	ns := s[0:i];
	for(; i < len s; i++){
		if(s[i] == '\n'){
			ns[len ns] = '\\';
			ns[len ns] = 'n';
		}else
			ns[len ns] = s[i];
	}
	return ns;
}

# sleep for t milliseconds, without worrying about int overflow
sleep(t: big)
{
	while(t > big 16r7fffffff){
		sys->sleep(16r7fffffff);
		t -= big 16r7fffffff;
	}
	sys->sleep(int t);
}

str2time(s: string): big
{
	(x, u) := str->tobig(s, 10);
	case u {
	"ms" =>
		;
	"" or
	"s" =>
		x *= big 1000;
	"h" =>
		x *= big (60 * 60 * 1000);
	"m" =>
		x *= big (60 * 1000);
	"d" =>
		x *= big (24 * 60 * 60 * 1000);
	* =>
		return big -1;
	}
	return x;
}

# avoid including keyring.m, security.m, etc.
randomint(): int
{
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil){
		logerror(sys->sprint("cannot open /dev/notquiterandom: %r"));
		return 0;
	}
	buf := array[4] of byte;
	sys->read(fd, buf, 4);
	rand := 0;
	for(i := 0; i < 4; i++)
		rand = (rand<<8) | int buf[i];
	return rand;
}

logmemusage()
{
	buf := array[1024] of byte;
	n := sys->pread(memfd, buf, len buf, big 0);
	if(n <= 0){
		log("no mem stats");
		return;
	}
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		s := hd lines;
		log(sys->sprint("mem %s %d %d %d", s[84:], int s[0:11], int s[36:47], int s[48:59]));
	}
}

ss(s: string): ref Sexp.String
{
	return ref Sexp.String(s, nil);
}

sl(l: list of ref Sexp): ref Sexp.List
{
	return ref Sexp.List(l);
}
