.TL
Owen™ Grid: Scheduler Administration
.NH 1
Notes for Owen™ Grid Administrators
.LP
This document is aimed at users who are responsible for the administration of 
an Owen™ Grid.  In particular it describes the log files that are created
both by the scheduler and each client which can be used to investigate problems
if they occur.
.NH 2
Server Side
.LP
.NH 3
Log Files
.LP
The scheduler writes various events to a log to
enable the user to see what it has been doing, this is mainly used for fault
tracking and debugging purposes. The log can be a file or a directory.
A log file is created as follows:
.P1
echo -n > /grid/master/log
.P2
All logged events will be appended to this file.
You can instead create a log directory:
.P1
mkdir /grid/master/log
.P2
The scheduler
will then create a series of log files within that directory. Each file name will be of the form
\f(CWlog.\fP\fItime\fP
where \fItime\fR is a 10 digit timestamp of the time the file was
created. This number can be given to the \f(CWdate\fR command to see the date and time in conventional form.
For example, given
.CW log.1088030774 :
.P1
% date 1088030774
Wed Jun 23 23:46:14 BST 2004
.P2
It is usually better to use a log directory not a single log file,
as it enables the scheduler to use the rollover function described
below.
.NH 3
Rollover
.LP
Periodically, the scheduler starts logging to a new
file. This partitions up the logs and enables the user to more easily find or
remove a log for a particular time as well as preventing the build up of huge
files. This only happens, however, when \f(CW/grid/master/log\fR is a directory. By default, rollover
occurs once a week; this can be changed with the \f(CW-L\fR option to the scheduler:
.P1
-L \fIloginterval\fP
.P2
where
.I loginterval
is an integer followed by a letter.
Possible letters are \f(CWms\fR (milliseconds), \f(CWs\fR
(seconds), \f(CWm\fR (minutes), \f(CWh\fR (hours) and \f(CWd\fR (days). 
The default time period is 1 week.
.NH 3
File Format
.LP
Each event is represented by a line in the log file,
containing space separated fields. The first field on each line is a 10 digit
field containing the timestamp of the event in number of milliseconds since the
scheduler was started. The remaining fields describe the event. The first event
in each log file is always \f(CWstarttime \fItime\f(CW\fR where \fI\f(CWtime\fI\fR
is the time the scheduler was started in milliseconds
since 1 January 1970.
For example:
.P1
0000000000 starttime 1087832739784
.br
0000002345 slave arrive 192.168.72.254!25984 inferno
.br
0000002788 slave name bob 192.168.72.254!25984
.br
0008727474 task new bob 192.168.72.254!25984 8c68c89f.4#3 tgid 2
.P2
.LP
To find the actual time of an event, simply
add the event time offset to the time the scheduler was started (you will need to
remove the last 3 digits of the result to pass it to \f(CWdate\fR).
Thus,
.DS
1087832739784 + 0008727474 = 1087841467(258)
.DE
and give the result to
.CW date :
.P1
% date 1087841467
Mon Jun 21 19:11:07 BST 2004
.P2
.LP
The format of each logged event depends on the event
but as a general rule, all job related events will have at least the job's
unique id associated with them and node events will hold the name and IP
address of the node.
.NH 3
Debugging
.LP
The scheduler can be made to log events more verbosely
by specifying the verbose flag \f(CW-v\fR in the command line arguments. 
This function is useful when troubleshooting
as it provides a much more detailed picture of what is going on. However, be
aware that the increased output can result in very large (hundreds of MB) log
files, so it is recommended that this option is not used if disk space is limited.
.NH 3
Working Area
.LP
The \f(CW/grid/master/work\fR directory is the scratch directory for the scheduler.
Each job has its own directory called \f(CW/grid/master/work/\fP\fIuniqueid\fP\f(CW.\fP\fIjobno\fP
where
.I uniqueid
is a random hexadecimal number and
.I jobno
is the number of the job. These directories
are used to store all the files required to execute the job: temporary data,
results etc. The
.I uniqueid
ensures that if the scheduler is restarted with no
dump to restore from and a new job is started with the same job number as one
that had been running before, it will not overwrite the old data. This is
important if, for example, the old data was from a semi-complete job and might
provide information as to why it did not succeed.
.NH 3
Blacklisting
.LP
When a client repeatedly fails tasks, the scheduler
will automatically \fIblacklist\fP the client and not give it any more work.
This stops a bad client from ruining a job and enables the grid administrators
to be able to easily identify problem clients. Once the client has been
repaired, it may be removed from the blacklist using the Node Monitor and will
start receiving work again.
.LP
Note: This scheme assumes that the only a small minority of
tasks within a job can fail on a good client. If a job is started where
most of the tasks fail even on good clients, then potentially all the clients
could end up being blacklisted.
.LP
Periodically (by default, every 10 minutes) clients
are automatically unblacklisted. This can be changed using the \f(CW-U\fP option:
.P1
-U \fIunblacklistinterval\fP
.P2
Where \fIunblacklistinterval\fP
is the period of time before a client is
automatically unblacklisted and uses the same format as the rollover interval 
\f(CW-L\fP.
.NH 3
Restarting the Scheduler
.LP
To restart the scheduler, simply kill off the old
process and re-run the startup script. The scheduler will automatically restore
its state from the most recent dump file and continue with the work it was
doing.
.NH 3
Dump Files
.LP
The scheduler periodically dumps its current working
state so that if it is shut down or crashes, it can carry on from the most
recent dump. The interval between dumps is specified as an option to the
scheduler of the form:
.P1
-D \fIdumpinterval\fP
.P2
where
.I dumpinterval
is the time between dumps and uses the
same format as the log rollover interval option \f(CW-L\fP. By default, 
the state is dumped every 10 seconds.
.LP
The dump files are all stored in \fP/grid/master\fP and have one of three 
possible names:
.TS
center ;
lw(1i)f(CW) lw(3i)fR .
dump	The most recent dump file.
dump.old	The previous dump file.
dump.restore\fIXXXXXXXXXX\fP	T{
A copy of the dump file that was used to restore the
scheduler. \fIXXXXXXXXXX\fP is a 10 digit timestamp of the time when the
scheduler was restored.
T}
.TE
.LP
When the scheduler is restarted, it automatically
tries to restore its state from the dump files. It first tries \f(CWdump\fP 
and then, if that does not exist, or is
corrupted, from \f(CWdump.old\fP.
.LP
The restore files may be used to restore the scheduler
to a known point. For example, if the scheduler was restarted but a required
file for one of the current jobs was missing, causing the restoration to fail
then the original dump file could be overwritten. This would mean that even
after the missing file had been retrieved, the job would be forgotten. However,
copying the last restore file over the dump file and then restarting the
scheduler would cause it to restart at the same point as before (i.e. with all
the original jobs) but this time with the required file in place.
.NH 3
Troubleshooting
.LP
Here is a list of some potential problems along with
the most likely solution:
.IP •
\fBJob just hangs\fP
.br
Check that there is at least one available
client that is capable of processing the tasks for the job. Also, ensure that
the task name is spelt correctly.
.IP •
\fBClients all get blacklisted\fP
.br
There is probably a problem with the job.
Make sure that all required executables and data files are installed and
available to the clients.
.IP •
\fBNo clients appear\fP
.br
Check that the scheduler and clients are
all using the same authentication mode.
.NH 2
Client Side
.NH 3
Log Files
.LP
Each client records significant events in its own log
file: \f(CW/grid/slave/log\fP. This file has the same structure as the
scheduler log file with one event per line and the first field being the number
of milliseconds since the client was started. The absolute time at which the
client was last started is given by the most recent \f(CWstart\fP event. For example:
.P1
0000000000 start 1089033266234
.br
0000000000 ++++++++++++++ start Mon Jul 05 14:14:26 BST 2004
.br
0000000031 new new version
.br
0000000047 initial attributes
.br
0000000047 attrs:
.br
0000000047 jobtype2 update
.br
0000000047 jobtype0 blast
.br
0000000047 scriptslave: attempting to mount server
.br
0000000547 scriptslave: mounted server
.br
0000000594 scriptslave: resubmit succeeded
.br
0000000594 scriptslave: get next task
.br
0000460719 scriptslave: got task 'bab730a0.24#55' (args: blast)
.P2
To find the
time the slave got its task:
.DS
1089033266234 + 0000460719 = 1089033726(953)
.DE
and
.P1
% date 1089033726
.br
Mon Jul 05 14:22:06 BST 2004
.P2
As with the
scheduler, it is possible to force the client to produce more verbose output
using the \f(CW-v\fP argument.
Again, this will result in much larger log files sizes but is usually worth
doing unless disk space is scarce.
