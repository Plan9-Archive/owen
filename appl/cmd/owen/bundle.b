implement Bundle;
include "sys.m";
	sys: Sys;
include "sh.m";
include "draw.m";
include "alphabet/fs.m";
	fs: Fs;
	Value, Fsdata, Fschan: import fs;
	fswrite, fsunbundle, fswalk, fsbundle: Fsmodule;
include "alphabet/reports.m";
	reports: Reports;
	Report: import reports;
include "bundle.m";

init()
{
	sys = load Sys Sys->PATH;
	fs = load Fs Fs->PATH;
	if(fs == nil)
		badmodule(Fs->PATH);
	reports = load Reports Reports->PATH;
	if(reports == nil)
		badmodule(Reports->PATH);
	fswrite = fsload("write");
	fsbundle = fsload("bundle");
	fsunbundle = fsload("unbundle");
	fswalk = fsload("walk");
}

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "bundle: cannot load %q: %r", p);
	raise "fail:bad module";
}

fsload(name: string): Fsmodule
{
	p := "/dis/alphabet/fs/"+name+".dis";
	m := load Fsmodule p;
	if(m == nil)
		badmodule(p);
	m->init();
	return m;
}

bundle(dir: string, fd: ref Sys->FD): string
{
	spawn reports->reportproc(errorc := chan of string, nil, reply := chan of ref Report);
	r := <-reply;
	# /fs/walk /grid/master/gold/auxfiles | hashfilter | /fs/bundle | create auxfiles.bun
	x := fswalk->run(nil, r, nil, ref Value.Vs(dir) :: nil);
	if(x == nil)
		return "fs/walk failed";
	x2 := ref Value.Vx(chan of (Fsdata, chan of int));
	spawn stripmetaproc(x.x().i, x2.i, r.start("stripmeta"));
	f := fsbundle->run(nil, r, nil, x2 :: nil);
	if(f == nil){
		x2.free(0);
		return "fs/bundle failed";
	}
	spawn wfd(f.f().i, fd);
	r.enable();
	stderr := sys->fildes(2);
	while((e := <-errorc) != nil)
		sys->fprint(stderr, "%s\n", e);
	return nil;
}

unbundle(fd: ref Sys->FD, dir: string): string
{
	spawn reports->reportproc(errorc := chan of string, nil, reply := chan of ref Report);
	r := <-reply;

	# /fs/unbundle fd | hashfilter | /fs/write destdir
	f := ref Value.Vf(chan of ref Sys->FD);
	spawn rfd(f.i, fd);

	x := fsunbundle->run(nil, r, nil, f :: nil);
	if(x == nil){
		f.free(0);
		return "/fs/unbundle failed";
	}
	x2 := ref Value.Vx(chan of (Fsdata, chan of int));
	spawn stripmetaproc(x.x().i, x2.i, r.start("stripmeta"));

	st := fswrite->run(nil, r, nil, x2 :: ref Value.Vs(dir) :: nil);
	if(st == nil){
		x2.free(0);
		return "/fs/write failed";
	}

	r.enable();
	st.r().i <-= nil;
	stderr := sys->fildes(2);
	nerr := 0;
	while((e := <-errorc) != nil){
		nerr++;
		sys->fprint(stderr, "%s\n", e);
	}
	<-st.r().i;
	if(nerr)
		return string nerr + " errors";
	return nil;
}

# normalise a file tree's metadata, prior to bundling:
# don't allow non-regular files through (append-only, exclusive use).
# don't allow non-rwx directories.
# also, copy user permissions to group and other permissions.
stripmetaproc(src, dst: Fschan, errorc: chan of string)
{
	indent := 0;
	myreply := chan of int;
loop:
	for(;;){
		(d, reply) := <-src;
		if(d.dir != nil){
			nd := ref Sys->nulldir;
			m := d.dir.mode;
			if(m & (Sys->DMEXCL|Sys->DMAPPEND))
				errorc <-= sys->sprint("warning: stripping mode bits %#ux from %q, indent %d", m, d.dir.name, indent);
			m &= Sys->DMDIR|8r700;
			umode := m&8r700;
			nd.mode = m | (umode >> 3) | (umode >> 6);
			if(indent > 0)
				nd.name = d.dir.name;
			else
				nd.name = ".";
			nd.length = d.dir.length;
			d.dir = nd;
		}
		dst <-= (d, myreply);
		case reply <-= <-myreply {
		Fs->Quit =>
			break loop;
		Fs->Next =>
			if(d.dir == nil && d.data == nil)
				if(--indent == 0)
					break loop;
		Fs->Skip =>
			if(--indent == 0)
				break loop;
		Fs->Down =>
			if(d.dir != nil)
				indent++;
		}
	}
	errorc <-= nil;
}

wfd(fdc: chan of ref Sys->FD, fd: ref Sys->FD)
{
	<-fdc;
	fdc <-= fd;
}

rfd(fdc: chan of ref Sys->FD, fd: ref Sys->FD)
{
	fdc <-= fd;
	<-fdc;			# unbundle will always send back a nil value.
}
