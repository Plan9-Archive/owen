#define Nproc 1

chan worktoken = [Nproc] of {bit};
chan newtask = [0] of {bit};
chan tasklock = [1] of {bit};
chan down = [0] of {int};

int nexcl = 0;
int nproc = 0;

#define EXCLUSIVE 2
#define EXISTS 1

active proctype mount()
{
	int t;
	do
	:: down?t ->
		_nr_pr < Nproc*2 + 4 ->
		run processor(t)
	od
}

proctype processor(int t)
{
	chan sync= [0] of {bit};
	chan treply = [0] of {int};
	/*
	 * resubmit old task
	 */
	if
	:: t & EXISTS ->
		if
		:: skip ->
			down!t ->
			goto exit
		:: skip ->
			run taskfinish(sync, t);
			sync?0
		fi
	:: else ->
		skip
	fi;

	do
	:: run runtask(treply) ->
		treply?t;
		if
		:: skip ->
			down!t;
			goto exit
		:: skip ->
			if
			:: t&EXISTS ->
				run taskfinish(sync, t);
				sync?0
			:: else
			fi
		fi
	od;

exit:
	skip
}

proctype runtask(chan treply)
{
	int t, i;
	chan sync = [0] of {bit};
	tasklock!0;
	newtask?0;
	
	if
	:: skip ->
		tasklock?0;
		treply!0;
		goto exit
	:: skip
	fi;

	/*
	 * getworktoken
	 */
	if
	:: skip ->	/* exclusive */
		t = EXCLUSIVE|EXISTS;
		i = 0;
		do
		:: i == Nproc ->
			break
		:: i < Nproc ->
			worktoken?0;
			i = i + 1
		od
	:: skip ->
		t = EXISTS;
		tasklock?0;
		worktoken?0
	fi;

	/*
	 * runtask2
	 */
	if
	:: skip ->		/* submit failed */
		treply!t;
		goto exit
	:: skip
	fi;

	run taskfinish(sync, t);
	sync?0;
	treply!0;
exit:
	skip
}

proctype taskfinish(chan sync; int t)
{
	int i;
	if
	:: t & EXCLUSIVE ->
		i = 0;
		do
		:: i == Nproc ->
			break
		:: i < Nproc ->
			worktoken!0;
			i = i + 1
		od;
		tasklock?0
	:: (t & EXCLUSIVE) == 0 ->
		worktoken!0
	:: else ->
		printf("shouldn't happen (t is %d)\n", t);
	fi;
	sync!0
}

active proctype taskgen()
{
progress: do
	:: newtask!0
	od
}

init
{
	int i;
	i = 0;
	do
	:: i == Nproc ->
		break;
	:: i < Nproc ->
		worktoken!0;
		down!0;
		i = i + 1
	od
}
