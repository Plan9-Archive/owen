implement Attributes;

Attributes: module {
	Attrs: adt[T] {
		a: list of (string, T);
		set: fn(a: self Attrs, attr: string, val: T): Attrs;
		get: fn(a: self Attrs, attr: string): T;
		del: fn(a: self Attrs, attr: string): Attrs;
	};
};

Attrs[T].get(a: self Attrs, attr: string): T
{
	for(; a.a != nil; a.a = tl a.a)
		if((hd a.a).t0 == attr)
			return (hd a.a).t1;
	return nil;
}

Attrs[T].set(a: self Attrs, attr: string, val: T): Attrs
{
	r: list of (string, T);
	for(l := a.a; l != nil; l = tl l){
		if((hd l).t0 == attr)
			return Attrs(join(r, (attr, val)::tl l));
		r = hd l :: r;
	}
	return Attrs((attr, val)::a.a);
}

Attrs[T].del(a: self Attrs, attr: string): Attrs
{
	r: list of (string, T);
	for(l := a.a; l != nil; l = tl l){
		if((hd l).t0 == attr)
			return Attrs(join(r, tl l));
		r = hd l :: r;
	}
	return a;
}

join[T](x, y: list of (string, T)): list of (string, T)
{
	if(len x > len y)
		(x, y) = (y, x);
	for(; x != nil; x = tl x)
		y = hd x :: y;
	return y;
}
