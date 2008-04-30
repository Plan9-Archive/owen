implement Taskgenerator;
include "sys.m";
	sys: Sys;
include "taskgenerator.m";
include "arg.m";
include "rand.m";
	rand: Rand;

ntasks := 100;
taskid := 0;
failurerate := 0.0;
failuremodes := "";			# i,c,h,w,r
taskduration := 2000;
jobbytes := 0;
resultbytes := 10;
maxtries := 20;

resultch: chan of int;
tasks: array of byte;

runargs(nil: list of string): list of string
{
	return nil;
}

init(nil: string, state: string, args: list of string): string
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		return sys->sprint("cannot load %s: %r", Arg->PATH);
	rand = load Rand Rand->PATH;
	if(rand == nil)
		return sys->sprint("cannot load %s: %r", Rand->PATH);
	arg->init(args);
	arg->setusage(nil);
	{
		while((opt := arg->opt()) != 0){
			case opt {
			'f' =>
				failurerate = real arg->earg();
				failuremodes = arg->earg();
			't' =>
				taskduration = int (real arg->earg() * 1000.0);
			'd' =>
				jobbytes = units(arg->earg());
				resultbytes = units(arg->earg());
			'r' =>
				maxtries = int arg->earg();
			* =>
				raise "fail:usage";
			}
		}
		args = arg->argv();
		if(len args != 1)
			raise "fail:usage";
		ntasks = int hd args;
	} exception {
	"fail:usage" =>
		return "usage: testgen [-f failure_rate modes] [-t task_time] [-d jobdata resultdata] [-r retries] numtasks";
	}
	tasks = array[ntasks+1] of {* => byte 0};
	resultch = chan of int;
	if(state != nil){
		e := restorestate(state);
		if(e != nil)
			return e;
	}
	spawn resultmonitor();
	return nil;
}

resultmonitor()
{
	while((id := <-resultch) != -1){
		if(int tasks[id] != 0)
			sys->print("duplicate result for task %d\n", id);
		tasks[id] = byte 1;
	}
}

opendata(nil: string,
		nil: int,
		nil: chan of Readreq,
		nil: chan of Writereq,
		nil: chan of int): string
{
	return "permission denied";
}
quit()
{
}

taskcount(): int
{
	return ntasks;
}

reconnect(id: string,
		read: chan of (int, chan of array of byte, chan of int),
		write: chan of (array of byte, chan of string, chan of int),
		finish: chan of (int, big, chan of string)): int
{
sys->print("testgen: reconnect %s\n", id);
	spawn taskproc(1, int id, nil, read, write, finish);
	return Started;
}

state(): string
{
	s := string taskid + " ";
	i := 0;
	for(;;){
		for(; i < len tasks; i++)
			if(tasks[i] != byte 0)
				break;
		if(i == len tasks)
			break;
		start := i;
		for(; tasks[i] != byte 0; i++)
			;
		if(i == start + 1)
			s += string start;
		else
			s += string start + "-" + string (i - 1);
	}
	return s;
}

restorestate(s: string): string
{
	(n, toks) := sys->tokenize(s, " ");
	taskid = int hd toks; toks = tl toks;
	tasks = array[ntasks+1] of {* => byte 0};
	for(; toks != nil; toks = tl toks){
		w := hd toks;
		for(i := 0; i < len s; i++)
			if(w[i] == '-')
				break;
		start := int w;
		end := start + 1;
		if(i < len s)
			end = int w[i+1:] + 1;
		for(j := start; j < end; j++){
			if(j >= ntasks)
				return "task record overflow at " + string j;
			if(tasks[j] != byte 0)
				sys->print("testgen: oops, clash at %d\n", j);
			tasks[j] = byte 1;
		}
	}
	return nil;
}

start(id: string,
	tries:	int,
	nil: ref Clientspec,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	if(tries >= maxtries)
		return (Nomore, nil);
#sys->print("start %#q (attrs: %#q, tries: %d)\n", id, spec.attrs, tries);
	if(id == nil){
		n := taskid++;
		if(taskid > ntasks)
			return (Nomore, nil);
		id = string n;
	}
	mode := 'g';
	if(frand() < failurerate)
		mode = failuremodes[rand->rand(len failuremodes)];
	spawn taskproc(0,
		int id,
		sys->sprint("%d %d %d %c", int id, taskduration, resultbytes, mode),
		read, write, finish
	);
	return (Started, id);
}

complete()
{
	for(i := 0; i < ntasks; i++)
		if(tasks[i] == byte 0)
			sys->print("task %d is not complete\n", i);
	sys->print("testgen: job is complete\n");
	resultch <-= -1;
}

taskproc(
	reconnected: int,
	id: int,
	spec: string,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string))
{
	result := "";
	params := array of byte spec;
	jobn := 0;
	inn := 0;
	candisconnect := 0;

	if(reconnected){
		candisconnect = 1;
		jobn = jobbytes;
	}

	for(;;) alt {
	(n, reply, flushc) := <-read =>
		alt{
		flushc <-= 1 =>
			;
		* =>			# flushed
			reply <-= nil;
			continue;
		}
		if(params != nil){
			if(n > len params)
				n = len params;
			reply <-= params[0:n];
			params = nil;
			if(jobbytes == 0)
				candisconnect = 1;
		}else if(jobn < jobbytes){
			if(jobn + n > jobbytes)
				n = jobbytes - jobn;
			reply <-= array[n] of {* => byte 1};
			jobn += n;
		}else{
			candisconnect = 1;
			reply <-= array[0] of byte;
		}
	(data, reply, flushc) := <-write =>
		alt{
		flushc <-= 1 =>
			inn += len data;
			reply <-= nil;
		* =>
			reply <-= "flush";
		}
	(first, duration, reply) := <-finish =>
		if(inn < resultbytes){
			if(candisconnect)
				reply <-= "disconnected";
			else
				reply <-= "premature eof";
		}else{
			if(first)
				resultch <-= id;
			reply <-= nil;
		}
		exit;
	}
}

frand(): real
{
	x: real;
	NORM: con 1.0 / (1.0 + real 16r7ffffffe);
	do{
		x = real rand->rand(16r7fffffff) * NORM;
		x = (x + real rand->rand(16r7fffffff)) * NORM;
	} while(x >= 1.0);
	return x;
}

units(s: string): int
{
	if(s == nil)
		return 0;
	c := s[len s - 1];
	case c {
	'0' to '9' =>
		return int s;
	'M' or
	'm' =>
		return int s * 1024 * 1024;
	'K' or
	'k' =>
		return int s * 1024;
	'G' or
	'g' =>
		return int s * 1024 * 1024 * 1024;
	* =>
		raise "fail:usage";
	}
}
