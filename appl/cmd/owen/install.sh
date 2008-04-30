#!/dis/sh
# usage install [-p pred]... [-A] schedaddr pkgname dir [dest]
# e.g. install -pplatform=Linux -pcputype=386 -A tcp!pranzo!6666 mypackage /tmp/something 

(addr pkg dir dest) = $*
run /lib/sh/owen

mount addr /n/remote
load alphabet
declares { |
	typeset /fs |
	type /fs/fs /string |
	import /fs/walk /fs/bundle /create /filter
}
jid := ${job update $pkg install $dest}
- {(string string)
	walk $1 |
	bundle |
	filter "{gzip} |
	create $2
} $dir /n/remote/admin/$jid/data
ctl $jid prereq match ...
ctl $jid start
