implement Mount;

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	auth: Auth;
include "mount.m";

init()
{
	sys = load Sys Sys->PATH;
	auth = load Auth Auth->PATH;
}

mount(addr, old: string, flag: int, aname: string, crypto, keyspec: string): (int, string)
{
#	if(sys->stat(old).t0 == -1)
#		return (-1, sys->sprint("cannot stat mountpoint %q: %r", old));
	addr = netmkaddr(addr, "net", "styx");
	ai: ref Keyring->Authinfo;
	if((flag & MNOAUTH) == 0 && (ai = auth->key(keyspec)) == nil)
		return (-1, sys->sprint("cannot find key: %r"));
	(ok, c) := sys->dial(addr, nil);
	if(ok == -1)
		return (-1, sys->sprint("cannot dial %q: %r", addr));
	user := "none";
	if((flag & MNOAUTH) == 0){
		if(crypto == nil)
			crypto = "md5/rc4_256";
		(fd, err) := auth->client(crypto, ai, c.dfd);
		if(fd == nil)
			return (-1, "authentication failed: "+err);
		user = err;
		c.dfd = fd;
	}
	flag &= ~MNOAUTH;
	if(sys->mount(c.dfd, nil, old, flag, aname) == -1)
		return (-1, sys->sprint("mount failed: %r"));
	return (0, user);
}

netmkaddr(addr, net, svc: string): string
{
	if(net == nil)
		net = "net";
	(n, nil) := sys->tokenize(addr, "!");
	if(n <= 1){
		if(svc== nil)
			return sys->sprint("%s!%s", net, addr);
		return sys->sprint("%s!%s!%s", net, addr, svc);
	}
	if(svc == nil || n > 2)
		return addr;
	return sys->sprint("%s!%s", addr, svc);
}
