
Mount: module {
	PATH: con "/dis/owen/mount.dis";

	MREPL: con Sys->MREPL;
	MBEFORE: con Sys->MBEFORE;
	MAFTER: con Sys->MAFTER;
	MCREATE: con Sys->MCREATE;
	MCACHE: con Sys->MCACHE;
	MNOAUTH: con 128;
	init: fn();
	mount: fn(addr, old: string, flag: int, aname: string, crypto, keyspec: string): (int, string);
};
