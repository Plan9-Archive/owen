Timetable: module {
	PATH: con "/dis/owen/timetable.dis";
	
	And, Or, Not: con iota;
	Range: adt {
		period: int;
		r: array of int;
	};

	Times: adt {
		r: list of (ref Range, ref Range);
		get: fn(t: self ref Times, time: int): (int, int);
	};
	init: fn();
	new: fn(spec: string): (ref Times, string);
	combine: fn(op: int, r1, r2: ref Range): ref Range;
};
