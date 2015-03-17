
A collection of computers can share computational and other resources to form a grid.

Owen™ is a labour exchange for a computational grid. Workers make themselves available for work at the exchange. Jobs to be done are posted at the labour exchanged, subdivided into smaller, potentially concurrent work tasks. Tasks are allocated to suitable available workers. By running a worker per node or per processor, the tasks are done in parallel on all available nodes. Owen tabulates the results from each node and a post-processing step can combine the results at the end of the job. Typically the worker software is run on a collection of Windows PCs or UNIX/Linux workstations, and the scheduler is run on a server somewhere. Owen is resilient to failures of workers, and the scheduler saves its state to allow it to be restarted elsewhere if the original scheduler machine fails (although that procedure is not yet automatic).

Owen is an Inferno application written in the concurrent programming language Limbo. The implementation is unusual. The labour exchange is a file server. Jobs are submitted, and workers obtain work, by reading and writing those files (following a particular convention).

Owen itself provides distributed computation, but workers (and thus the jobs they do) can access other resources using standard resource-sharing operations in Inferno, to build a complete grid.

Owen relies on the portable system environment provided by Inferno on Windows, Linux, Solaris, MacOSX, etc., and on Inferno's support for implementing distributed applications as file servers.

The software is named after Robert Owen, who invented the first Labour Exchange.