Attributes: module {
	PATH: con "/dis/owen/attributes.dis";
	Attrs: adt[T] {
		a: array of (string, T);
		new: fn(): Attrs;
		add: fn(a: self Attrs, attr: string, val: T): Attrs;
		get: fn(a: self Attrs, attr: string): T;
		fetch: fn(a: self Attrs, attr: string): (int, T);
		del: fn(a: self Attrs, attr: string): Attrs;
		merge: fn(a: self Attrs, b: Attrs): Attrs;
	};
};
