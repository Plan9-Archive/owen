TGsimple: module {
	PATH: con "/dis/owen/tgsimple.dis";
	Params: adt {
		maxretries: int;
		pendtasks: int;
		keepall: int;
		keepfailed: int;
		verbose: int;
	};
	Defaultparams: con Params(5, 5, 0, 0, 0);
	init: fn(p: Params, jobargs: list of string, root, work, state: string,
			kick: chan of int, m: Simplegen): (chan of ref Taskgenerator->Taskgenreq, string);
};

Simplegen: module {
	# XXX return from init could tell whether random access was allowed on tasks.
	simpleinit: fn(root, work: string, state: string): (int, string);
	state: fn(): string;
	get: fn(fd: ref Sys->FD): int;
	verify: fn(n: int, fd: ref Sys->FD): string;
	put: fn(n: int, fd: ref Sys->FD);
	complete: fn();
	quit: fn();
	opendata: fn(
		user: string,
		mode: int,
		read:		chan of Taskgenerator->Readreq,
		write:	chan of Taskgenerator->Writereq,
		clunk:	chan of int): string;
};
