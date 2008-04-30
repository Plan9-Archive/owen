Taskgenerator: module {
	Started, Error, Nomore: con iota;

	Readreq: type (int, chan of array of byte, chan of int);
	Writereq: type (array of byte, chan of string, chan of int);
	Finishreq: type (int, big, chan of string);

	Clientspec: adt {
		addr: string;
		user: string;
		attrs: Attributes->Attrs[string];
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
			duration: int;
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
			reply: chan of (int, string);
		State =>
			reply: chan of string;
		Complete =>
		}
	};

	init: fn(root, work, state: string, kick: chan of int, args: list of string): (chan of ref Taskgenreq, string);
};

# pre-filter clients for a task generator.
Prereq: module {
	init: fn(argv: list of string): string;
	ok: fn(spec: ref Taskgenerator->Clientspec): int;
};
