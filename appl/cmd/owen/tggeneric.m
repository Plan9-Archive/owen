TGgeneric: module {
	PATH: con "/dis/owen/tggeneric.dis";
	Param: adt {
		name: string;
		pick{
		File =>
			hash: array of byte;
			size: big;
			kind: string;
			fd: ref Sys->FD;
			soff, eoff: big;
		Value =>
			v: list of string;
		}
	};
	Task: adt {
		id: string;
		instid: string;
		taskargs: list of string;
		params: list of ref Param;
		out: ref Sys->FD;
		outkind: string;
		errfile: string;
	};
	init: fn(): string;
	start: fn(gen: Simplegen): chan of ref Taskgenerator->Taskgenreq;
	checkspec: fn(spec: ref Taskgenerator->Clientspec, tasktype: string, space: big): string;
	hash: fn(fd: ref Sys->FD, soff, eoff: big): array of byte;
};

Simplegen: module {
	state: fn(): string;
	taskcount: fn(): int;
	start: fn(id: string, tries: int, spec: ref Taskgenerator->Clientspec): (int, ref TGgeneric->Task, string);
	reconnect: fn(id: string): (ref TGgeneric->Task, string);
	verify: fn(t: ref TGgeneric->Task, duration: big): string;
	finalise: fn(t: ref TGgeneric->Task, ok: int);
	complete: fn();
	quit: fn();
	opendata: fn(
		user: string,
		mode: int,
		read:		chan of Taskgenerator->Readreq,
		write:	chan of Taskgenerator->Writereq,
		clunk:	chan of int): string;
};
