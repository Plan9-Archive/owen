implement Attributes;
include "attributes.m";

Attrs[T].new(): Attrs[T]
{
	a: Attrs[T];
	return a;
}

getattr[T](a: Attrs[T], attr: string): (int, int, T)
{
	i0 := 0;
	i1 := len a.a - 1;
	while (i0 <= i1){
		i := (i0 + i1) >> 1;
		(ai, vi) := a.a[i];
		if(attr < ai)
			i1 = i-1;
		else if(attr > ai)
			i0 = i+1;
		else
			return (1, i, vi);
	}
	return (0, i0, nil);
}

Attrs[T].get(a: self Attrs, attr: string): T
{
	return a.fetch(attr).t1;
}

LINEAR: con 6;
Attrs[T].fetch(a: self Attrs, attr: string): (int, T)
{
	# linear search is considerably faster when n is small.
	if((n := len a.a) < LINEAR){
		for(i := 0; i < n; i++)
			if(a.a[i].t0 == attr)
				return (1, a.a[i].t1);
		return (0, nil);
	}
	(found, nil, v) := getattr(a, attr);
	return (found, v);
}

Attrs[T].add(a: self Attrs, attr: string, val: T): Attrs
{
	(found, i, nil) := getattr(a, attr);
	if(found){
		a.a[i].t1 = val;
		return a;
	}
	na := array[len a.a + 1] of (string, T);
	na[0:] = a.a[0:i];
	na[i] = (attr, val);
	na[i+1:] = a.a[i:];
	return Attrs(na);
}

Attrs[T].del(a: self Attrs, attr: string): Attrs
{
	b: Attrs[T];
	(found, i, nil) := getattr(a, attr);
	if(found){
		na := array[len a.a - 1] of (string, T);
		na[0:] = a.a[0:i];
		na[i:] = a.a[i+1:];
		a = Attrs(na);
	}
	return b;
}

# merge a0 with a1, giving precedence to attributes in a1.
Attrs[T].merge(a0: self Attrs, a1: Attrs): Attrs
{
	if(len a0.a == 0)
		return a1;
	if(len a1.a == 0)
		return a0;
	r := array[len a0.a + len a1.a] of (string, T);
	i0 := i1 := j := 0;
	while(i0 < len a0.a && i1 < len a1.a){
		s0 := a0.a[i0].t0;
		s1 := a1.a[i1].t0;
		if(s0 < s1){
			r[j++] = a0.a[i0++];
		}else if(s0 > s1){
			r[j++] = a1.a[i1++];
		}else{
			r[j++] = a1.a[i1++];
			i0++;
		}
	}
	if(i1 < len a1.a){
		i0 = i1;
		a0 = a1;
	}
	while(i0 < len a0.a)
		r[j++] = a0.a[i0++];
	if(j < len r)
		r = (array[j] of (string, T))[0:] = r[0:j];
	return Attrs[T](r);
}
