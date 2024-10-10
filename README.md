<!--
Copyright 2021 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Solution Overview
This script collects information from provided Azure account and generates csv files for import into StratoZone for analysis.
Generated files will be placed in ./output directory and compressed as zip files. Created zip files can be imported directly to StratoZone using the import procedure. 

**NOTE:** Script will collect data only on the instances user executing the script has access to. 


- [Solution Overview](#solution-overview)
- [StratoZone Azure export usage](#stratozone-azure-export-usage)
- [Prerequisites](#prerequisites)
- [Azure Permissions](#Azure-Permissions)
- [Support](#Support)
<!--
- [Optional Features & Configuration](#optional-features--configuration)
  - [Single Region as source(all VMs in project analyzed)](#single-project-analysis-all-vms-in-project-analyzed)
-->  

# StratoZone Azure Export Usage
- Step 1: Login to Azure Console (https://portal.azure.com)

- Step 2: Launch Cloud Shell \
!["Image of Cloud Shell Console highlighting an icon with a greater-than and underscore"](images/console_button.png)

- Step 3: Clone Script repo
```
git clone https://github.com/GoogleCloudPlatform/azure-to-stratozone-export.git
```

- Step 4: Access cloned project directory
```
cd azure-to-stratozone-export
```

- Step 5: Run script to start collection
```
./azure-export.ps1
```

**NOTE:** When the target environment includes a large number of machines, or has poor connectivity to them, the Azure credentials might timeout before done collecting all the data. Possible mitigation are: running repeated collections on subsets of machines, or running the collection script from a VM inside the Azure environment.

- Step 6: Verify output file has been generated
```
 ls ./*.zip
```

- Step 7: When the script completes, click on Upload/Download files icon.
 !["Image of Cloud Shell Download files"](images/download_output.png)

 - Step 8: Enter the path to the output file.
    - Step 8a: For virtual machine collection
    ```
    /azure-to-stratozone-export/vm-azure-import-files.zip
    ```
    - Step 8b: For managed service collection
    ```
    /azure-to-stratozone-export/services-azure-import-files.zip
    ```

 - Step 9: Click Download. File is ready for import into StratoZone portal.


# Script Optional Parameters
* -no_perf - Default False. Use to indicate whether performance data will collected.
```
./azure-export -no_perf
```
* -threadLimit - Default 30. Use to set the maximum number of threads to start during performance data collection.
```
./azure-export -threadLimit 40
```
* -no_public_ip - Default False. Use to indicate whether public IP address will be collected.
```
./azure-export -no_public_ip
```
* -no_resources - Default False. Use to indicate whether deployed resources are collected.
```
./azure-export -no_resources
```

# Prerequisites
  Azure Cloud Shell is the recommended environment to execute the collection script as it has all required components (PowerShell and Azure PowerShell module) already installed.

  If the script will be executed from a workstation following components will need to be installed
  - PowerShell 7.0.6 LTS, PowerShell 7.1.3, or higher 
  - Azure Az PowerShell module (https://docs.microsoft.com/en-us/powershell/azure/install-az-ps?view=azps-6.5.0)


# Azure Permissions
  The script needs read-only access to the Azure Subscriptions where collection will be performed.


# Support
If the execution of the script fails please contact stratozone-support@google.com and attach log file located in ./output directory.
