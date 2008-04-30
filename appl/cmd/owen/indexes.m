Indexes: module {
	PATH: con "/dis/owen/indexes.dis";
	init: fn();
	Index: adt {
		index: ref Bufio->Iobuf;
		start: int;
		nrecs: int;
		filesize: big;

		open: fn(index, file: string): (ref Index, string);
		create: fn[T](index, file: string, t: T): (ref Index, string)
			for{
			T =>
				skiprec: fn(t: self T, iob: ref Bufio->Iobuf): int;
			};
		offsetof: fn(i: self ref Index, recno: int): big;
	};
};

