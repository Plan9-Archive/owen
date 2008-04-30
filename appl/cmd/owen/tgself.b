implement TGself;
include "attributes.m";
include "taskgenerator.m";
	Taskgenreq, Readreq, Writereq, Finishreq, Clientspec: import Taskgenerator;
include "tgself.m";

init(state: string, argv: list of string, gen: Taskgenmod): (chan of ref Taskgenreq, string)
{
	r := chan of (chan of ref Taskgenreq, string);
	spawn taskgenproc(state, argv, gen, r);
	return <-r;
}

taskgenproc(state: string, argv: list of string, gen: Taskgenmod,
		reply: chan of (chan of ref Taskgenreq, string))
{
	if((e := gen->tginit(state, argv)) != nil){
		reply <-= (nil, e);
		exit;
	}
	reqch := chan of ref Taskgenreq;
	reply <-= (reqch, nil);
	reply = nil;

	while((req := <-reqch) != nil){
		pick r := req {
		Taskcount =>
			r.reply <-= gen->taskcount();
		Opendata =>
			r.reply <-= gen->opendata(r.user, r.mode, r.read, r.write, r.clunk);
		Start =>
			r.reply <-= gen->start(r.tgid, r.failed, r.spec, r.read, r.write, r.finish);
		Reconnect =>
			r.reply <-= gen->reconnect(r.tgid, r.read, r.write, r.finish);
		State =>
			r.reply <-= gen->state();
		Complete =>
			gen->complete();
		}
	}
	gen->quit();
}
