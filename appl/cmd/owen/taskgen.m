Taskgenerator: module {
	Started, Error, Nomore: con iota;

	Readreq: type (int, chan of array of byte, chan of int);
	Writereq: type (array of byte, chan of string, chan of int);
	Finishreq: type (int, big, chan of string);

	Clientspec: adt {
		addr: string;
		attrs: list of (string, string);
		nodeattrs: list of (string, string);
	};

	Taskgenreq: adt {
		pick {
		Taskcount =>
			reply: chan of int;
		Opendata =>
			user: string;
			mode: int;
			read:		chan of Readreq;
			write:	chan of Writereq;
			clunk:	chan of int;
			reply:	chan of string;
		Start =>
			tgid: string;
			failed: int;
			spec: ref Clientspec;
			read:		chan of Readreq;
			write:	chan of Writereq;
			finish:	chan of Finishreq;
			reply: chan of (int, string);
		Reconnect =>
			tgid: string;
			read:		chan of Readreq;
			write:	chan of Writereq;
			finish:	chan of Finishreq;
			reply: chan of int;
		State =>
			reply: chan of string;
		Complete =>
		}
	};

	init:		fn(jobid: string, state: string, args: list of string): (chan of ref Taskgenreq, string);
};

Simplegen: module {
	init: fn[T](root, jobid: string, argv: list of string,
			admin2sched: chan of (array of byte, chan of string),
			sched2admin: chan of array of byte): (chan of ref Taskgenreq, string)
		for{
		T =>
			get:		fn(fd: ref Sys->FD): int;
			verify:	fn(n: int, fd: ref Sys->FD): string;
			put:		fn(n: int, fd: ref Sys->FD);
			complete:	fn();
			quit:		fn();
		};
};
