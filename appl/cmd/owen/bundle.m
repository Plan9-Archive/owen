Bundle: module {
	PATH: con "/dis/owen/bundle.dis";
	init: fn();
	bundle: fn(dir: string, fd: ref Sys->FD): string;
	unbundle: fn(fd: ref Sys->FD, dir: string): string;
};
