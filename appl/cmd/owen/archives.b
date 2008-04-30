implement Archives;
include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str:	String;
include "archives.m";

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "archives: cannot open %s: %r\n", Bufio->PATH);
		raise "fail:bad module";
	}
	str = load String String->PATH;
	if(str == nil){
		sys->fprint(sys->fildes(2), "archives: cannot open %s: %r\n", String->PATH);
		raise "fail:bad module";
	}
}

Archive.new(f: string): ref Archive
{
	iob := bufio->create(f, Sys->OWRITE, 8r666);
	if(iob == nil)
		return nil;
	return ref Archive(iob, 1);
}

Archive.startsection(a: self ref Archive, name: string, fields: array of string)
{
	if(len fields == 0)
		raise sys->sprint("error:section %#q has no fields", name);
	for(i := 0; i < len fields; i++)
		if(fields[i] == nil)
			raise sys->sprint("error:field name %d in section %#q is empty", i, name);
	if(a.atstart)
		a.atstart = 0;
	else
		putc(a.iob, '\n');
	puts(a.iob, sys->sprint("%q\n%q", name, fields[0]));
	for(i = 1; i < len fields; i++)
		puts(a.iob, sys->sprint(" %q", fields[i]));
	putc(a.iob, '\n');
}

Archive.write(a: self ref Archive, vals: array of string)
{
	puts(a.iob, sys->sprint("%q", cvt2external(vals[0])));
	for(i := 1; i < len vals; i++)
		puts(a.iob, sys->sprint(" %q", cvt2external(vals[i])));
	putc(a.iob, '\n');
}

Archive.close(a: self ref Archive)
{
	check(a.iob.flush());
}

putc(iob: ref Iobuf, c: int)
{
	check(iob.putc(c));
}

puts(iob: ref Iobuf, s: string)
{
	check(iob.puts(s));
}

check(status: int)
{
	if(status == Bufio->ERROR)
		raise sys->sprint("error:write error: %r");
}

Unarchive.new(f: string): ref Unarchive
{
	iob := bufio->open(f, Sys->OREAD);
	if(iob == nil)
		return nil;
	return ref Unarchive(iob, nil, nil, 0);
}

Unarchive.expectsection(u: self ref Unarchive, name: string, fields: array of string)
{
	if(u.sect != nil)
		raise sys->sprint("parse:section %q not ended, expected %q", u.sectname, name);
	toks := str->unquoted(u.iob.gets('\n'));
	if(toks == nil || tl toks != nil)
		raise sys->sprint("parse:expected section header %q", name);
	if(hd toks != name)
		raise sys->sprint("parse:expected section %q; found %q", name, hd toks);
	toks = str->unquoted(u.iob.gets('\n'));
	if(toks == nil)
		raise sys->sprint("parse:no fields in section %q", name);
	sect := array[len toks] of {* => -1};
	found := array[len fields] of {* => 0};

	for(i := 0; toks != nil; (i, toks) = (i+1, tl toks)){
		f := hd toks;
		for(j := 0; j < len fields; j++){
			if(fields[j] == f){
				sect[i] = j;
				found[j] = 1;
				break;
			}
		}
	}
	for(i = 0; i < len found; i++)
		if(!found[i])
			raise sys->sprint("parse:in section %q, field %q not found", name, fields[i]);
	u.sect = sect;
	u.sectname = name;
	u.nfields = len fields;
}

Unarchive.getsection(u: self ref Unarchive): (string, array of string)
{
	if(u.sect != nil)
		raise sys->sprint("parse:section %q not ended yet", u.sectname);
	toks := str->unquoted(u.iob.gets('\n'));
	if(toks == nil || tl toks != nil)
		raise sys->sprint("parse:expected section header");
	sectname := hd toks;
	toks = str->unquoted(u.iob.gets('\n'));
	if(toks == nil)
		raise sys->sprint("parse:no fields in section %q", sectname);
	sect := array[len toks] of int;
	fields := array[len sect] of string;
	for(i := 0; i < len sect; i++){
		sect[i] = i;
		fields[i] = hd toks;
		toks = tl toks;
	}
	u.sect = sect;
	u.sectname = sectname;
	u.nfields = len sect;
	return (sectname, fields);
}

Unarchive.read(u: self ref Unarchive): array of string
{
	if(u.sect == nil)
		raise "parse:not in section";
	toks := str->unquoted(u.iob.gets('\n'));
	if(toks == nil){
		u.sect = nil;
		u.sectname = nil;
		return nil;
	}
	if(len toks != len u.sect)
		raise "parse:wrong number of fields";
	r := array[u.nfields] of string;
	for(i := 0; toks != nil; (toks, i) = (tl toks, i+1))
		if(u.sect[i] != -1)
			r[u.sect[i]] = cvt2internal(hd toks);
	return r;
}

cvt2external(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\\')
			break;
	if(i == len s)
		return s;
	ns := s[0:i];
	for(; i < len s; i++){
		if(s[i] == '\n'){
			ns[len ns] = '\\';
			ns[len ns] = 'n';
		}else if(s[i] == '\\'){
			ns[len ns] = '\\';
			ns[len ns] = '\\';
		}else
			ns[len ns] = s[i];
	}
	return ns;
}

cvt2internal(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\\')
			break;
	if(i == len s)
		return s;
	ns := s[0:i];
	for(; i < len s - 1; i++){
		c := s[i];
		if(c == '\\'){
			c = s[++i];
			if(c == 'n')
				ns[len ns] = '\n';
			else
				ns[len ns] = c;
		}else
			ns[len ns] = c;
	}
	if(i < len s)
		ns[len ns] = s[len s - 1];
	return ns;
}
