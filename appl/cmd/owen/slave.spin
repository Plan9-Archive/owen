#define Nproc 4

chan proctokens = [Nproc] of {bit};
chan newtask = [0] of {bit};
chan plock = [1] of {bit};

int nexcl = 0;
int nproc = 0;

proctype processor(int pid)
{
	int i;
progress:	do
	:: plock?0 ->
		plock!0 ->
		proctokens?0 ->
		newtask?0 ->
			if
			:: skip ->		/* exclusive */
				if
				:: plock?0
				:: else ->
					proctokens!0 ->
					plock?0 ->
					proctokens?0
				fi;
				/* get all tokens that we don't already have */
				i = 1;
				do
				:: i < Nproc ->
					proctokens?0;
					i = i + 1
				:: else ->
					break
				od;
				plock!0;
				/*
				 * process exclusive task here
				 */
				atomic{nexcl = nexcl + 1};
				atomic{nexcl = nexcl - 1};
				/* give all tokens back */
				i = 0;
				do
				:: i < Nproc ->
					proctokens!0;
					i = i + 1
				:: else ->
					break
				od
			:: skip ->		/* non-exclusive */
				/*
				 * process task here
				 */
				atomic{nproc = nproc + 1};
				atomic{nproc = nproc - 1};
				proctokens!0;
			fi
	od	
}

active proctype proccheck()
{
	atomic{nexcl > 1 || nproc > Nproc || (nexcl > 0 && nproc > 0)} ->
		assert(0)
}

proctype taskgen()
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
		proctokens!0;
		run processor(i);
		i = i + 1
	od;
	plock!0;
	run taskgen()
}
