### 1.5.1 (2022-12-21)

### Improvement
* Change datetime format to ISO standard (yyyy-mm-dd hh:mm:ss)
* Add PrimaryMACAddress column to vmInfo data file
* Add MemoryUtilizationPercentage column to perfInfo file

### 1.4.4 (2022-12-21)

### Bug Fixes
* Add additional performance data verification

### 1.4.3 (2022-11-21)

### Bug Fixes
* Fix scenario where performance data columns are returned in different order to what was requested.

### 1.4.1 (2022-04-28)

### Improvement
* Add resource collection. List of deployed resource will be imported along with VM data to provide possible mapping to GCP resources.

### 1.3.3 (2022-04-28)

### Bug Fixes
* Capture errors occurring during performance data retrieval.

### Improvement
* Add ability to skip public IP address collection. 


### 1.1.6 (2022-02-22)

### Bug Fixes
* add conversion for scientific numbers to decimal
* add support for disk collection for powered off vms

### Improvement
* increase VM performance data collection using threads


