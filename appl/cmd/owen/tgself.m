TGself: module {
	PATH: con "/dis/owen/tgself.dis";
	init: fn(state: string, argv: list of string, m: Taskgenmod): (chan of ref Taskgenerator->Taskgenreq, string);
};

Taskgenmod: module {
	tginit:	fn(state: string, args: list of string): string;
	taskcount: fn(): int;
	state: fn(): string;
	opendata: fn(
		user: string,
		mode: int,
		read:		chan of Taskgenerator->Readreq,
		write:	chan of Taskgenerator->Writereq,
		clunk:	chan of int): string;
	start: fn(id: string,
		failed:	int,
		spec: ref Clientspec,
		read:		chan of Taskgenerator->Readreq,
		write:	chan of Taskgenerator->Writereq,
		finish:	chan of Taskgenerator->Finishreq): (int, string);
	reconnect: fn(id: string,
		read:		chan of Taskgenerator->Readreq,
		write:	chan of Taskgenerator->Writereq,
		finish:	chan of Taskgenerator->Finishreq): (int, string);
	complete:	fn();
	quit:	fn();
};
