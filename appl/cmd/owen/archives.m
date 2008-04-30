Archives: module{
	PATH: con "/dis/owen/archives.dis";
	init: fn();

	Archive: adt {
		iob:	ref Bufio->Iobuf;
		atstart: int;
	
		new:		fn(f: string): ref Archive;
		startsection:	fn(a: self ref Archive, name: string, fields: array of string);
		write:	fn(a: self ref Archive, vals: array of string);
		close:	fn(a: self ref Archive);
	};

	Unarchive: adt {
		iob:	ref Bufio->Iobuf;
		sectname: string;
		sect:	array of int;
		nfields: int;
	
		new:		fn(f: string): ref Unarchive;
		expectsection:	fn(u: self ref Unarchive, name: string, fields: array of string);
		getsection:	fn(u: self ref Unarchive): (string, array of string);
		read:			fn(u: self ref Unarchive): array of string;
	};
};
