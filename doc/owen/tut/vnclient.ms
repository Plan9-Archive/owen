.TL
Owen™ Grid: Client Installer for Windows 2000/XP
.NH 1
Windows client installer
.LP
The Owen Grid
Client Installer copies the grid client from the local machine to one
or more machines on the local network. Before starting the installer, ensure
that the folder
.CW C:\eeVNClient
on the local machine contains the version of the grid
client you wish to copy to other machines.
.NH 2
Startup
.LP
When started, the Client Installer first scans the network to obtain a list
of accessible domains and the machines within them. During this time a
progress dialog box is displayed:
.BP vnclient_images/image001.ps 0.5i
.NH 2
Browsing a domain
.LP
In order to see a list of machines within a domain, click on the drop
down list box and select a domain from the list. The
installer will then attempt to connect to each machine in the domain to obtain
the state of the grid client. If login details are required to access
the machine, the installer will prompt for a username and password:
.BP vnclient_images/image002.ps 1i
Once the
installer has queried the machines within the domain it presents the results in
the main window:
.BP vnclient_images/image003.ps 3i
.LP
Each machine name is listed, together with the relevant
information about the state of its grid client. If the installer cannot
connect to a machine, no information will be displayed for it.
.LP
The list may be sorted by any field by clicking on the corresponding column header.
.NH 2
Updating machines
.LP
Select machines by clicking on list entries.
You can select more than one.
(Clicking on a selected entry deselects it.)
You can then act on all selected machines:
.IP •
The DVD `play' and `stop' icons
start and stop the
.CW InfernoGridSlave
service on all selected machines.
They do nothing if the service is already started (stopped).
.IP •
The
.CW install
button  installs the worker software.  The contents of the
.CW C:\eVNClient
folder will be copied from the local 
machine to all selected machines. The
.CW InfernoGridSlave
service will also be installed.
.IP •
The
.I "work folder"
.CW C:\eVNClient\egrid\eslave
is used for temporary storage while
tasks are being processed and thus the contents are not normally copied from
the local machine. If you
.I do
wish to copy the contents of the
work folder, then tick the box
before installing the client(s).
.IP •
The
.CW remove
button can be used to stop the
.CW InfernoGridClient
service and remove all the files in the
.CW C:\eVNClient
folder on each of the selected machines.
.NH 2
Other Options
.IP •
The
.CW Refresh
button
causes the installer to re-query all the machines in the
current domain. It will not, however, scan for new machines.
.IP •
The
.CW Export
button creates a text file containing the
information displayed about each machine in the current domain
.IP •
Excluding machines: if there are machines that you do not wish the
installer to query, they may be excluded. To do this, create a file called
.CW exclude.txt
in the same folder as the installer. This file should contain a
list of all the machines you wish to exclude, one per line.
The character
.CW *
matches any string, so that
.CW \e\eDA*
would match any machine name beginning with `\f(CWDA\fP' such as
.CW \e\eDAVID
or
.CW \e\eDANIEL .
If this file exists then the
.CW "Exclude machines"
tickbox will be ticked by default.
Any machines that are excluded will have `Excluded' written as their
OS Version. Unchecking the tickbox will stop excluding any machines and a
subsequent refresh will cause the installer to query the domain, including any
previously excluded machines.
.IP •
Viewing a single machine: rather than browsing a whole domain,
if you want to connect to a single machine
that you know by name, select the
.CW "single machine"
option in the
.CW Domain
drop down list:
.BP vnclient_images/image013.ps 0.25i
.LP
A window will pop up to prompt for the name of the machine:
.BP vnclient_images/image012.ps 0.5i
.LP
Once this has been entered, the installer
will attempt to connect to the machine and display its status in the main
window.
.EP
