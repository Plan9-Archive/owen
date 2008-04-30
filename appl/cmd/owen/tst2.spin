active proctype x()
{
	do
	:: _nr_pr == 1 ->
		run f()
	od
}

proctype f()
{
	chan sync = [0] of {bit};
}
