.FP palatino
.TL
Installing Owen™ \(em the Inferno Computational Grid software
.AU
Vita Nuova
.br
20 September 2005
.NH 1
Package contents
.LP
The installation CD contains software for both grid clients (workers) and the server (scheduler, labour exchange).
The components are
in separate directories in the root directory of the CD:
.CW client
and
.CW server .
There is just one scheduler for any grid system, possibly running on a machine
reserved for that purpose; there will usually be many workers, but for initial testing
it is probably best to install on only a few, then replicate the installation once that works.
The grid software itself is portable, as is its core installation software,
but unfortunately there are details of the installation that depend on the host system.
This document therefore describes server and client installation in separate sections,
and within each section describes installation on Windows and non-Windows machines in separate subsections.
It is fine to use different machine or operating system types for
scheduler and and clients, including a mix of client types;
of course, any particular computation will run only on a client that can run the software required.
.NH 1
Server software
.LP
The grid server software can be installed on a Unix-like (Linux, FreeBSD, Solaris)
or Microsoft Windows (2000 and XP) platforms. These two groups have separate
installation instructions.
.NH 2
Server software on Unix-like systems
.LP
The grid server software will be installed in the directory
.CW /grid/inferno ,
which should either not exist or be empty.
.LP
The operating system will usually mount the CD at some system-specific place,
called
.I cd_path
here
(on Linux, this is usually
.CW /mnt/cdrom ).
Other parameters in the instructions are
.I host_os ,
which names the host operating system, and
.I host_arch ,
which names the processor architecture.
The choice for
.I host_os
is from
.CW Linux ,
.CW FreeBSD ,
.CW Solaris ,
.CW Irix ,
.CW MacOSX
and
.CW Plan9 .
.I Host_arch
is chosen from
.CW 386
(which includes 486, Pentium, and all later Intel 32/64 architectures),
.CW mips ,
.CW power
or
.CW sparc ;
usually it will be
.CW 386
for nearly everything except
.CW MacOSX
for which it is
.CW power .
.IP 1.
In a shell (eg, `New Terminal') window, type the following command:
.P1
sh \fIcd_path\fP/server/install/\fIhost_os\fP-grid-\fIhost_arch\fP.sh
.P2
Assuming it has permission to do so, the script will populate
.CW /grid/inferno
with the Inferno distribution, including the grid scheduler components.
.IP 2.
The file
.CW \fIcd_path\fP/server/install/startsched.sh
contains a Bourne shell script that can be copied to an appropriate
place on your system, or used as the basis for one of your own,
to simplify starting the scheduler.
In particular it sets the right bin directory in
.CW PATH
to find Inferno's controlling program (called
.I emu ),
and starts it with the right parameters to find the
.CW /grid/inferno
directory and start the scheduler in the right environment.
Note that in the current version, it initially assumes an unauthenticated grid,
and starts unauthenticated network listeners, exporting the local file system
and the capability to run local programs to anyone on the local network.
A later section explains how to configure the system to use authentication to control access.
.LP
Now check that
.CW /grid/inferno/grid/master/config
contains the right network address for your scheduler.
The manual pages
.I owen-intro (1)
and
.I scheduler (1)
in
.CW scheduler.pdf
on the CD give more details on invoking the scheduler in
different ways.
.NH 2
Server software on Windows
.LP
The grid server software will be installed on Windows 2000/XP machines in the directory (folder)
.CW c:\eVNServer .
.IP •
On a Windows machine that has the CD loaded, use Windows Explorer (or equivalent)
to move to the directory named
.CW server\einstall
on the CD.
.IP •
Double-click
.CW setup.exe
in that directory.
It will display a new window that prompts for a destination directory.
The directory need not exist but if it does, it should be empty.
The default should be
.CW C:\eVNServer .
You can change the name if required (eg, because
.CW C:
lacks space), but
you will then need to edit the shortcut that starts the server.
Hit the
.SM ENTER
key to start installation.
The program will prompt for permission to create the directory if it does not already exist.
It will then populate it with all files required by the server.
The installation will also create a shortcut on the desktop
that will start the server when activated.
.NH 1
Client software
.LP
As with servers, the installation instructions differ between Windows and Unix(-like) systems.
.NH 2
Client software for Windows
.LP
The grid client software will be installed on Windows NT4/2000/XP machines,
in the directory (folder)
.CW C:\eVNClient .
.IP 1.
On a Windows machine with the CD loaded,
use Windows Explorer (or equivalent) to move to the directory named
.CW \eclient\einstall
on the CD.
.IP 2.
Double-click
.CW setup.exe
in that directory.
It will display a new window that prompts for a destination directory.
The directory need not exist but if it does, it should be empty.
The default should be
.CW C:\eVNClient .
You can change the name if required (eg, because
.CW C:
lacks space), but
you will then need to edit several files, as discussed below,
and make appropriate changes to the instructions below.
Hit the
.SM ENTER
key to start installation.
The program will prompt for permission to create the directory if it does not already exist.
It will then populate it with all files required by the client.
.IP 3.
Move in Explorer to the directory
.CW C:\eVNClient\egrid\eslave .
Check that the file
.CWconfig
contains the right address for your scheduler machine.
If you changed the drive letter, you must also change the
four
.CW .bat
files in the directory to replace the
.CW C:
drive letter by the one you used.
.IP 4.
Choose which tasks the worker is allowed to perform.
Each potential task is represented by a
.CW .job
file in
.CW grid\eslave .
By default there are no tasks installed.
The directory
.CW grid\eslave\etasks
contains several possible such files, for instance:
.RS
.IP •
.CW test.job
allows the client to run anything (it is probably foolish to install this if the network is not completely trusted)
.IP •
.CW gold.job
allows Gold compute jobs
.IP •
.CW charmm.job
allows
.SM CHARMM
compute jobs
.IP •
.CW update.job
allows software updates and data distribution
.LP
To enable a task, copy its
.CW .job
file into the
.CW grid\eslave
directory.
.RE
.IP 5.
You can now add the grid client as a Windows service by running the appropriate
.CW .bat
file on the client.
Use
.IP
\f5install_service.bat\fP
for Windows 2000 and Windows XP
.RS
.IP \fIOR\fP
\f5install_service_nt4.bat\fP
for Windows NT4
.LP
Just double-clicking in Explorer on the chosen name should install the service.
.LP
Once installed as a service the client software will start automatically when
the client machine next boots.
You can start it manually using the Windows Services Manager in the usual way.
There are two
.CW .bat
files to remove the service (when desired): \f5remove_service.bat\fP
for 2000/XP and \f5remove_service_nt4.bat\fP for NT4.
.RE
.LP
The manual page
.I owen-intro (1)
in the PDF file
.CW \escheduler.pdf
on the CD gives more details on running and configuring the client software.
The manual page
.I owen-monitor (1)
in the same PDF file describes the use of the Client Monitor software.
.LP
On Windows machines you can remove the directory
.CW C:\eVNClient\eLinux
to reduce the space required on Windows clients.
.NH 2
Client software on Unix-like systems
.LP
Follow the instructions for installing the server software under Unix,
substituting
.CW client
for
.CW server
in file names throughout.
Furthermore, if the server software is already installed on the client under
.CW /grid/inferno ,
you will need to choose a new directory to use as
.I inferno_root
and give that name as parameter when running the actual install command.
For example:
.P1
sh \fIcd_path\fP/client/install/\fIhost_os\fP-grid-\fIhost_arch\fP.sh \fIinferno_root\fP
.P2
There is no common way on Unix systems to have the Inferno client run
automatically at boot-time, so you will have to arrange something
yourself, perhaps by adding the client start script to the local system's
startup script (which might need the help of the system's administrator).
.NH 1
Installing on many clients
.LP
We have found the best way to install many Windows clients is to install a client on
one machine, and then replicate it, once that installation and its configuration have been
tested against a working scheduler.
We typically replicate a configured installation by copying it to a USB storage key,
then visiting each machine in turn to copy in those files.
An alternative is to use the older `Grid Client Installer for WIndows 2000/XP',
described in a separate document.
It uses Windows file sharing to copy files to other machines in a given domain.
.LP
It is possible to share most of an installation (eg, using NFS on Unix systems)
but it is essential that each worker machine has its own
.CW /grid/slave/work
directory.
