implement Updategen, Taskgenerator, Taskgenmod;
include "sys.m";
	sys: Sys;
include "keyring.m";
	keyring: Keyring;
include "readdir.m";
	readdir: Readdir;
include "daytime.m";
	daytime: Daytime;
include "string.m";
	str: String;
include "arg.m";
include "attributes.m";
	attributes: Attributes;
	Attrs: import attributes;
include "taskgenerator.m";
include "tgself.m";

Updategen: module {
};

Updatefile: adt {
	vers: int;
	fd: ref Sys->FD;
	md5: string;
	refcount: int;
};

action := "install";
pkg: string;
verbose: int;
rootdir: string;
workdir: string;
startedwriter := 0;
fileref: chan of ref Updatefile;
filechange: chan of (string, string, chan of string);

Predicate: adt {
};

init(root, work, state: string, nil: chan of int, argv: list of string): (chan of ref Taskgenreq, string)
{
	sys = load Sys Sys->PATH;
	tgself := load TGself TGself->PATH;
	if(tgself == nil)
		return (nil, sys->sprint("cannot load %s: %r", TGself->PATH));
	gen := load Taskgenmod "$self";
	if(gen == nil)
		return (nil, sys->sprint("cannot self as Taskgenmod: %r"));
	rootdir = root;
	workdir = work;
	return tgself->init(state, argv, gen);
}

tginit(state: string, args: list of string): string
{
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return sys->sprint("cannot load %q: %r", Keyring->PATH);
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		return sys->sprint("cannot load %q: %r", Readdir->PATH);
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return sys->sprint("cannot load %q: %r", Daytime->PATH);
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load %q: %r", String->PATH);
	attributes = load Attributes Attributes->PATH;
	if(attributes == nil)
		return sys->sprint("cannot load %q: %r", Attributes->PATH);
	arg := load Arg Arg->PATH;
	arg->init(args);
	USAGE: con "usage: update [-v] pkgname [action [arg...]]";

	while((opt := arg->opt()) != 0){
		case opt {
		'v' =>
			verbose = 1;
		* =>
			return USAGE;
		}
	}
	args = arg->argv();
	if(args == nil)
		return USAGE;
	pkg = hd args;
	if(tl args != nil)
		action = str->quoted(tl args);
	fileref = chan[1] of ref Updatefile;
	if(state == nil)
		fileref <-= nil;
	else
		fileref <-= scandir();
	filechange = chan of (string, string, chan of string);
	spawn filemonproc();
	return nil;
}

quit()
{
	filechange <-= (nil, nil, nil);
}

taskcount(): int
{
	return -1;
}

reconnect(nil: string,
		nil: chan of (int, chan of array of byte, chan of int),
		nil: chan of (array of byte, chan of string, chan of int),
		nil: chan of (int, big, chan of string)): (int, string)
{
	return (Nomore, "no reconnecting allowed");
}

state(): string
{
	return "nil";
}

start(id: string,
	nil:	int,
	spec: ref Clientspec,
	read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string)): (int, string)
{
	if(id != nil)
		return (Nomore, "no restart");
	u := startupdate();
	if(u == nil){
		if(verbose)
			sys->print("debug no update available\n");
		return (Error, "no update available");		# XXX could register kickchan for later
	}
	if(!canupdate(spec) || !needsupdate(spec, u)){
		if(verbose)
			sys->print("debug client %q does not need updating\n", spec.addr);
		endupdate(u);
		return (Error, "no update needed");
	}
	if(verbose)
		sys->print("debug updating %q with pkg %s, version %s.%d\n", spec.addr, pkg, u.md5, u.vers);
	spawn updateproc(read, write, finish, u,
		sys->sprint("update %q %s %d %s", pkg, u.md5, u.vers, action));
	return (Started, "updatetask");
}
	
complete()
{
}

scandir(): ref Updatefile
{
	if(verbose)
		sys->print("log scanning dir\n");
	(d, e) := readdir->init(workdir, Readdir->NONE|Readdir->COMPACT);
	if(e == -1){
		sys->print("log cannot read %q: %r\n", workdir);
		return nil;
	}
	# find most recent version
	maxv := -1;
	for(i := 0; i < len d; i++){
		name := d[i].name;
		if(prefix(name, "pkg.") && (vers := version(name)) > maxv)
			maxv = vers;
	}

	# remove all but most recent version
	for(i = 0; i < len d; i++){
		name := d[i].name;
		if(maxv == -1 || version(name) < maxv)
			sys->remove(workdir+"/"+name);
	}
	if(maxv == -1){
		if(verbose)
			sys->print("log nothing found\n");
		return nil;
	}

	fd := sys->open(name("pkg", maxv), Sys->OREAD);
	if(fd == nil){
		sys->print("log cannot open %#q: %r\n", name("pkg", maxv));
		return nil;
	}
	md5 := readfile(name("md5", maxv));
	if(md5 == nil || len unhex(md5) != Keyring->MD5dlen){
		sys->print("log invalid md5 contents %#q\n", md5);
		return nil;
	}
	if(verbose)
		sys->print("log found old file version %d\n", maxv);
	return ref Updatefile(maxv, fd, md5, 0);
}

version(f: string): int
{
	for(i := len f - 1; i >= 0; i--)
		if(f[i] == '.')
			break;
	if(i == len f - 1 || f[i+1] < '0' || f[i+1] > '9')
		return -1;
	return int f[i+1:];
}

opendata(nil: string,
		mode: int,
		nil: chan of Readreq,
		wreq: chan of Writereq,
		clunk: chan of int): string
{
	if((mode & ~Sys->OTRUNC) != Sys->OWRITE)
		return "permission denied";
	if(startedwriter)
		return "already open";
	fd := sys->create(workdir+"/pkg.partial", Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create: %r");
	startedwriter = 1;
	spawn writeproc(fd, wreq, clunk);
	return nil;
}

writeproc(fd: ref Sys->FD, wreq: chan of Writereq, clunk: chan of int)
{
	if(writeproc1(fd, wreq, clunk) != 0){
		while(((nil, reply) := getwritereq(wreq, clunk)).t1 != nil)
			reply <-= "transaction finished";
	}
	fd = nil;
	sys->remove(workdir+"/pkg.partial");
	startedwriter = 0;
}

# write a new update file.
# return non-zero if the conversation hasn't yet terminated.
writeproc1(fd: ref Sys->FD, wreq: chan of Writereq, clunk: chan of int): int
{
	if(verbose)
		sys->print("in writeproc\n");
	state: ref Keyring->DigestState;
	while(((d, reply) := getwritereq(wreq, clunk)).t1 != nil && len d > 0){
		if(sys->write(fd, d, len d) != len d){
			reply <-= sys->sprint("%r");
			return 1;
		}
		state = keyring->md5(d, len d, nil, state);
		reply <-= nil;
	}
	if(reply == nil)
		sys->print("log transfer possibly incomplete\n");
	digest := array[Keyring->MD5dlen] of byte;
	keyring->md5(nil, 0, digest, state);
	fd = nil;
	creply := chan of string;
	filechange <-= (workdir+"/pkg.partial", hex(digest), creply);
	e := <-creply;
	if(reply != nil)
		reply <-= e;
	if(e != nil)
		sys->print("log error registering new update file: %s\n", e);
	return reply != nil;
}

getwritereq(wreq: chan of Writereq, clunk: chan of int): (array of byte, chan of string)
{
	for(;;)alt{
	(d, reply, flushc) := <-wreq =>
		alt{
		flushc <-= 1 =>
			return (d, reply);
		* =>
			reply <-= "flushed";
			continue;
		}
	<-clunk =>
		return (nil, nil);
	}
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

Readjobargs, Readdata: con iota;

updateproc(read: chan of (int, chan of array of byte, chan of int),
	write: chan of (array of byte, chan of string, chan of int),
	finish: chan of (int, big, chan of string),
	u: ref Updatefile,
	args: string)
{
	state := Readjobargs;
	offset := big 0;
	done := 0;
	failure := "";
	for(;;)alt{
	(n, reply, flushc) := <-read =>
		data: array of byte;
		case state {
		Readjobargs =>
			data = array of byte args;
		Readdata =>
			data = array[n] of byte;
			n = sys->pread(u.fd, data, len data, offset);
			if(n == 0)
				done = 1;
			if(n < 0)
				n = 0;
			data = data[0:n];
		}
		alt{
		flushc <-= 1 =>
			reply <-= data;
			if(state == Readdata)
				offset += big n;
			else
				state++;
		* =>
			reply <-= nil;
		}
	(data, reply, flushc) := <-write =>
		failure += string data;
		alt{
		flushc <-= 1 =>
			reply <-= nil;
		* =>
			reply <-= "flushed";
		}
	(nil, nil, reply) := <-finish =>
		if(!done)
			reply <-= "incomplete";
		else if(failure != nil)
			reply <-= failure;
		else
			reply <-= nil;
		endupdate(u);
		exit;
	}
}

canupdate(spec: ref Clientspec): int
{
	a := spec.attrs.a;
	for(i := 0; i < len a; i++)
		if(prefix(a[i].t0, "jobtype") && a[i].t1 == "update")
			return 1;
	return 0;
}

needsupdate(spec: ref Clientspec, u: ref Updatefile): int
{
	v := spec.attrs.get("version_"+pkg);
	if(v == nil)
		return 1;
	(sum, vers) := parseversion(v);
	if(verbose)
		sys->print("debug client version %s.%d\n", sum, vers);
	return vers < u.vers;
}

parseversion(val: string): (string, int)
{
	for(i := 0; i < len val; i++)
		if(val[i] == '.')
			break;
	if(i == len val){
		log(sys->sprint("found invalid version: %q", val));
		return (nil, -1);
	}
	score := val[0:i];
	d := unhex(val[0:i]);
	if(len d != Keyring->MD5dlen){
		log(sys->sprint("invalid md5sum in version %q", val));
		return (nil, -1);
	}
	return (score, int val[i+1:]);
}

log(s: string)
{
	sys->print("%s\n", s);
}

hex(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

unhex(s: string): array of byte
{
	d := array[len s / 2] of byte;
	for(i := 0; i < len s; i++){
		c := s[i];
		case s[i] {
		'0' to '9' =>
			c -= '0';
		'a' to 'f' =>
			c -= 'a' - 10;
		'A' to 'F' =>
			c -= 'A' - 10;
		* =>
			return nil;
		}
		if((i & 1) == 0)
			d[i>>1] = byte (c << 4);
		else
			d[i>>1] |= byte c;
	}
	return d;
}

startupdate(): ref Updatefile
{
	u := <-fileref;
	if(u != nil)
		u.refcount++;
	fileref <-= u;
	return u;
}

endupdate(u: ref Updatefile)
{
	nu := <-fileref;
	--u.refcount;
	if(nu != u && u.refcount == 0){
		sys->remove(name("pkg", u.vers));
		sys->remove(name("md5", u.vers));
	}
	fileref <-= nu;
}

filemonproc()
{
	while(((f, md5, reply) := <-filechange).t2 != nil){
		sys->print("log new file %q md5=%s\n", f, md5);
		u := <-fileref;
		if((fd := sys->open(f, Sys->OREAD)) == nil){
			fileref <-= u;
			reply <-= sys->sprint("cannot open %q: %r", f);
			continue;
		}
		nu := ref Updatefile(daytime->now(), fd, md5, 0);
		if(u != nil){
			if(u.refcount == 0){
				sys->remove(name("pkg", u.vers));
				sys->remove(name("md5", u.vers));
			}
			if(nu.vers == u.vers){
				sys->sleep(1000);		# don't be so hasty
				nu.vers++;
			}
		}
		# XXX if this fails, we've lost the old version...
		rename(f, "pkg."+string nu.vers);
		writefile(name("md5", nu.vers), md5);
		fileref <-= nu;
		reply <-= nil;
	}
}

name(base: string, ver: int): string
{
	return workdir+"/"+base+"."+string ver;
}

writefile(f: string, s: string): int
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	d := array of byte s;
	if(sys->write(fd, d, len d) == -1)
		return -1;
	return 0;
}

readfile(f: string): string
{
	buf := array[8192] of byte;
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

rename(f1, name: string): int
{
	d := Sys->nulldir;
	d.name = name;
	r := sys->wstat(f1, d);
	if(r == -1)
		log(sys->sprint("cannot rename %q to %q: %r\n", f1, name));
	return r;
}
