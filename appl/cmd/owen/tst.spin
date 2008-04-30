proctype fact(int n; chan p)
{
	chan child = [1] of {int};
	int result;
	if
	:: n <= 1 -> p!1
	:: n >= 2 ->
		run fact(n-1, child);
		child?result;
		p!n+result
	fi
}

init
{
	chan child = [1] of {int};
	int result;

	run fact(400, child);
	child?result;
	printf("result: %d\n", result);
}
