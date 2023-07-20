#!/usr/bin/env pwsh
<#
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

#>

# Version 1.5.2


[cmdletbinding()]
param (
  [switch]$no_perf=$false,
  [int]$threadLimit=30,
  [switch]$no_public_ip=$false,
  [switch]$no_resources=$false,
  [ValidateSet('INFO', 'DEBUG')]
  [System.String]$log_level='INFO'
)
<#
	.DESCRIPTION
	Collects VM data from existing Azure subscriptions

	.PARAMETER no_perf
	Default False. Use to indicate whether performance data will collected.

	.PARAMETER threadLimit
	Default 30. Use to set the maximum number of threads to start

	.PARAMETER no_public_ip
	Default False. Use to indicate whether public IP address will be collected and stored.

	.PARAMETER no_resources
	Default False. Use to indicate whether resource collection is performed.

	.PARAMETER log_level
	Default 'INFO'. Use to indicate whether the log level is INFO or DEBUG.

	.EXAMPLE
    PS> ./azure-export -no_perf
    PS> ./azure-export -threadLimit 40
	PS> ./azure-export -no_public_ip
	PS> ./azure-export -no_resources
#>

$global:vmObjectList = @()
$global:vmTagsList = @()
$global:vmDisksList = @()
$global:vmPerfData = @()
$resourceListlist=@()

$subList = Get-AzSubscription
$global:outputPath = "$(Get-Location)\output\"
$global:LogFile = "$outputPath\stratozone-azure-export.log"
$global:LogLevel = $log_level


$ipInfo = [PSCustomObject]@{
    publicIp     = ""
    primaryIp    = ""
	primaryMac   = ""
    ipList       = ""
  }

# Write message to log. Timestamp is added along with the message
function LogMessage
{
    param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)
	try{
    	Add-content $global:LogFile -value ((Get-Date).ToString() + " - " + $Message)
	}
	catch{
		Write-Host "Unable to Write to log file"
	}
}

#check if disk size is valid
function CheckDiskSizeValue(){
	param
	(
		[Parameter(Mandatory = $true)]
			$diskSize
	)
		if([string]::IsNullOrEmpty($diskSize)){
			return 0
		}

		if ($diskSize -gt 0){
			return $diskSize
		}
		else {
			return 0
		}
}

#get disk info for deallocated VM
function GetDiskInfoForPoweredOffVm{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$diskName,
		#resource group
		[Parameter(Mandatory = $true)]
		$diskResourceGroup
	)
		$disk = Get-AzDisk -Name $diskName -ResourceGroupName $diskResourceGroup -erroraction 'silentlycontinue'
		if(-Not $disk){
			throw "Unable to collect data for disk name: " + $diskName
		}

		return $disk.DiskSizeGB, $disk.Sku.Name
}

#Add disk data to the global array for specified VM
Function SetDiskInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm,
		#VM status info
		[Parameter(Mandatory = $true)]
		$vmStatusInfo
	)

	
	# collect info on all disks attached tot he VM
	# UsedInGib data is unavailable in Azure and it will be left empty.

    $diskSize = 52.5
	$diskType = "Premium_LRS"

	foreach($disk in $vm.StorageProfile.DataDisks){
        $diskSize = 52.5
	    $diskType = "Premium_LRS"
		try{
			if($vmStatusInfo.Statuses[1].DisplayStatus -ne "VM running"){
				if($disk.ManagedDisk){
					$diskSize, $diskType = GetDiskInfoForPoweredOffVm $disk.Name $vm.ResourceGroupName
				}
				else{
					$diskSize = $disk.DiskSizeGB
					$diskType = "Standard HDD LRS"
				}
			}	
			else{
				$diskSize = $disk.DiskSizeGB
				$diskType = "Standard HDD LRS"
				if($disk.ManagedDisk){
					$diskType = $disk.ManagedDisk.StorageAccountType
				}
			}
		}
		catch{
			LogMessage("Unable to collect data disk info for: " + $vm.Name + " with state: " + $vmStatusInfo.Statuses[1].DisplayStatus)
       }
      	$vmDataDisk = [pscustomobject]@{
				"MachineId"=$vm.VmId
				"DiskLabel"=$disk.Name
				"SizeInGib"= CheckDiskSizeValue($diskSize) 
				"UsedInGib"=""
				"StorageTypeLabel"=$diskType
			}

		$global:vmDisksList += $vmDataDisk
	}

	
	# Add OS disk to the list of disks for VM
	# UsedInGib data is unavailable in Azure and it will be left empty.
    $diskSize = 52.5
	$diskType = "Premium_LRS"
    
	try{
		if($vmStatusInfo.Statuses[1].DisplayStatus -eq "VM running"){
			$diskSize = $vm.StorageProfile.OSDisk.DiskSizeGB
			$diskType = "Standard HDD LRS"

			if($vm.StorageProfile.OsDisk.manageddisk){
				$diskType = $vm.StorageProfile.OSDisk.ManagedDisk.StorageAccountType
			}
		}
		else{
			if($vm.StorageProfile.OsDisk.manageddisk){
				$diskSize, $diskType = GetDiskInfoForPoweredOffVm $vm.StorageProfile.OSDisk.Name $vm.ResourceGroupName
			}
			else{
				$diskSize = $vm.StorageProfile.OSDisk.DiskSizeGB
				$diskType = "Standard HDD LRS"
			}
		}
	}
	catch{
		LogMessage("Unable to collect OS disk info for: " + $vm.Name + " with state: " + $vmStatusInfo.Statuses[1].DisplayStatus)
 	}

	$vmOsDisk = [pscustomobject]@{
		"MachineId"=$vm.VmId
		"DiskLabel"=$vm.StorageProfile.OSDisk.Name
		"SizeInGib"= CheckDiskSizeValue($diskSize)
		"UsedInGib"=""
		"StorageTypeLabel"=$diskType
	}
	$global:vmDisksList += $vmOsDisk
	return		
}

#Add vm tags to the global array for provided VM
function SetVmTags{
	param
	(
		#VM
		[Parameter(Mandatory = $true)]
		$vm,
		#Tag Key
		[Parameter(Mandatory = $false)]
		$tagKey,
		#Tag Value
		[Parameter(Mandatory = $false)]
		$tagValue
	)
	foreach($key in $vm.Tags.Keys){
		$vmTags = [pscustomobject]@{
			"MachineId"=$vm.VmId
			"Key"= $key
			"Value"= $vm.Tags[$key]		
		}

		$global:vmTagsList += $vmTags
	}

	if(![string]::IsNullOrWhiteSpace($tagKey) -And ![string]::IsNullOrWhiteSpace($tagValue)){
		$vmTags = [pscustomobject]@{
			"MachineId"=$vm.VmId
			"Key"= $tagKey
			"Value"= $tagValue
		}
		$global:vmTagsList += $vmTags		
	}

	return
}



#Get IP info for VM that is part of a scale set
function GetVssVmIpInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm,

		# Public IP address for VMSS 
		[Parameter(Mandatory = $true)]
		$publicIp
	)

	$ipInfo.primaryIp = ""
	$ipInfo.ipList = ""
	$ipInfo.publicIp = ""
	$ipInfo.primaryMac = ""

	foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
		$nicConfig = Get-AzResource -ResourceId $nic.Id 
		foreach($ipConfig in $nicConfig.Properties.IpConfigurations){
			$ipInfo.ipList = $ipInfo.ipList + $ipConfig.Properties.PrivateIpAddress + ";"
	
			if ([string]::IsNullOrWhiteSpace($ipInfo.primaryIp)){
				$ipInfo.primaryIp = $ipConfig.Properties.PrivateIpAddress
			}
			if ([string]::IsNullOrWhiteSpace(	$ipInfo.primaryMac)){
				$ipInfo.primaryMac = $nicConfig.Properties.MacAddress
			}
		}
	}
	if(-Not $no_public_ip){
		if(![string]::IsNullOrWhiteSpace($publicIp)){
			$ipInfo.ipList = $ipInfo.ipList + $publicIp + ";"
		}
	}

	if($ipInfo.ipList.Length -gt 1){
		$ipInfo.ipList = $ipInfo.ipList.Substring(0,$ipInfo.ipList.Length -1)
	}

	return $ipInfo
}

#Get IP info for VM
function GetVmIpinfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm
	)

	$ipInfo.primaryIp = ""
	$ipInfo.ipList = ""
	$ipInfo.publicIp = ""
	$ipInfo.primaryMac = ""

	foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
		try{
			$nicConfig = Get-AzResource -ResourceId $nic.Id | Get-AzNetworkInterface

			foreach($ipConfig in $nicConfig.IpConfigurations){
				$ipInfo.ipList = $ipInfo.ipList + $ipConfig.PrivateIpAddress + ";"

				if(-Not $no_public_ip){
					foreach($pip in $ipConfig.PublicIpAddress){
						$pubIp = Get-AzResource -ResourceId $pip.id | Get-AzPublicIpAddress
						if($pubIp.IpAddress -ne "Not Assigned" -And ![string]::IsNullOrWhiteSpace($pubIp.IpAddress)){
							$ipInfo.publicIp = $pubIp.IpAddress 
							$ipInfo.ipList = $ipInfo.ipList + $pubIp.IpAddress + ";"
						}
					}
				}
				
				if ([string]::IsNullOrWhiteSpace($ipInfo.primaryIp)){
					$ipInfo.primaryIp = $ipConfig.PrivateIpAddress
				}
				if ([string]::IsNullOrWhiteSpace($ipInfo.primaryMac)){
					$ipInfo.primaryMac = $nicConfig.MacAddress
				}
			}
		}
		catch{
			$errorMsg = $_.Exception.Message
			$vmId = $vm.VmId
			$line = $_.InvocationInfo.ScriptLineNumber
	
			LogMessage "Error - GetVmIpinfo - vmid:$vmId - $errorMsg at $line"
		}
	}
	if($ipInfo.ipList.Length -gt 1){
		$ipInfo.ipList = $ipInfo.ipList.Substring(0,$ipInfo.ipList.Length -1)
	}

	return $ipInfo
}

function IsValidVmStatus{
	param
	(
		[Parameter(Mandatory = $true)]
		$vmStatusInfo
	)
	try
	{
		$vmStatus = $vmStatusInfo.Statuses[1].DisplayStatus
		if($vmStatus -eq "Deleting"){
			return $false
		}
	}
	catch{
		$errorMsg = $_.Exception.Message
		LogMessage "Error - IsValidVmStatus - value:$vmStatus - $errorMsg"
	}

	return $true
}

function FormatDateToISO{
	param
	(
		[Parameter(Mandatory = $true)]
		$dateTime
	)
	try
	{
		return $dateTime.ToString("yyyy-MM-dd HH:mm:ssK").Replace("Z", "+00:00")
	}
	catch{
		$errorMsg = $_.Exception.Message
		LogMessage "Error - FormatDateToISO - value:$dateTime - $errorMsg"
		return $dateTime
	}
}

#Add VM info to the global array for specified VM
function SetVmInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm,

		# IP data
		[Parameter(Mandatory = $true)]
		$ipInfo,

		#VM size
		[Parameter(Mandatory = $true)]
		$vmSizeInfo,

		#VM status
		[Parameter(Mandatory = $true)]
		$vmStatusInfo,

		#VmType
		[Parameter(Mandatory = $true)]
		$vmSizeName
	)
	
	$tmpTimeStamp = ""
	if ($vmStatusInfo.Statuses[0].Time){
		$tmpTimeStamp = FormatDateToISO($vmStatusInfo.Statuses[0].Time)
	}

	$vmBasicInfo = [pscustomobject]@{
		"MachineId"=$vm.VmId
		"MachineName"=$vm.Name
		"PrimaryIPAddress"=$ipInfo.primaryIp
		"PrimaryMACAddress"=$ipInfo.primaryMac
		"PublicIPAddress"=$ipInfo.publicIp
		"IpAddressListSemiColonDelimited"=$ipInfo.ipList
		"TotalDiskAllocatedGiB"=""
		"TotalDiskUsedGiB"=""
		"MachineTypeLabel"=$vmSizeName
		"AllocatedProcessorCoreCount"=$vmSizeInfo.NumberOfCores
		"MemoryGiB"= [math]::Round($vmSizeInfo.MemoryInMb /1024,1)
		"HostingLocation"=$vm.Location
		"OsType"=$vm.StorageProfile.osDisk.OsType
		"OsPublisher"=$vm.StorageProfile.ImageReference.Publisher
		"OsName"=$vm.StorageProfile.ImageReference.Offer
		"OsVersion"=$vm.StorageProfile.ImageReference.Sku
		"MachineStatus"=$vmStatusInfo.Statuses[1].DisplayStatus
		"ProvisioningState"=$vmStatusInfo.Statuses[0].DisplayStatus
		"CreateDate"=$tmpTimeStamp
		"IsPhysical"="0"
		"Source"="Azure"
	}

	$global:vmObjectList += $vmBasicInfo
	return
}


# Delete data from previous executions
try{
	if (!(Test-Path $outputPath)){
		New-Item -itemType Directory -Path $outputPath 
	}
	else{
		Remove-Item "$(Get-Location)\*.zip"
		Remove-Item "$outputPath\*.csv"
		Remove-Item "$outputPath\*.json"
	}
}
catch{
		Write-Host "Error creating output directory" -ForegroundColor yellow
}


LogMessage("Starting collection script")
$vmCount = 0
$vmsscount = 0
# Loop through all subscriptions user has access to
foreach ($sub in $subList){
	LogMessage("Processing Subscription $sub.Name")

	Select-AzSubscription -SubscriptionId $sub.Id
	Set-AzContext -SubscriptionId $sub.Id

	$vmPerfList = @()
	$vmStatusInfo = $null
	$vmSizeInfo = $null

	if(-Not $no_resources){
		#Get list of deployed resources
		$resources = Get-AzResource 
		foreach ($r in $resources) {
			$resourceListlist+=New-Object -TypeName PSObject -Property @{
				Name = $r.name
				ResourceType = $r.ResourceType
				Location=$r.Location
				ResoureceGroup = $r.ResourceGroupName 
				Tags = $r.tags
				Source = "Azure"
			}
		}
	}

	$vmList = Get-AzVM -erroraction 'silentlycontinue'
		
    # Loop through all VMs in resource group
    foreach($vm in $vmList){

        if($vmCount -eq 0 -or $vmCount % 5 -eq 0){
            Write-Progress -Activity "VM Collection" -Status "$vmCount of $($vmList.Length)"
        }
				$vmStatusInfo = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -erroraction 'silentlycontinue'

				if($vmStatusInfo){
					if((IsValidVmStatus($vmStatusInfo)) -eq $false){
						LogMessage("Unsupported VM status: $vmStatusInfo.Statuses[1].DisplayStatus ")
						continue
					}
				}

        $vmSizeInfo = Get-AzVMSize -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName | Where-Object{$_.Name -eq $vm.HardwareProfile.VmSize} -erroraction 'silentlycontinue'
      
        if($vmSizeInfo -and $vmStatusInfo) {
            $ipInfo = GetVmIpinfo($vm)
        
            SetVmTags $vm
            SetVmInfo $vm $ipInfo $vmSizeInfo $vmStatusInfo $vm.HardwareProfile.VmSize
            SetDiskInfo $vm $vmStatusInfo

			#if enabled add vm vm to perf collection array
            if(-Not $no_perf){
                $vmPerfIds = [PSCustomObject]@{
                    "vmID"   = $vm.VmId
                    "rid"    = $vm.Id
					"vmMem"  = $vmSizeInfo.MemoryInMb
                    }
                $vmPerfList += $vmPerfIds
            }
        }
        	
        $vmCount = $vmCount + 1
    }
    Write-Progress -Activity "VM Collection" -Status "$vmCount of $($vmList.Length)"
    

    LogMessage("Processing Vmss")
    $vmssList = Get-AzVmss  -erroraction 'silentlycontinue'

    foreach($vmss in $vmssList){
        $vmListfromVmss = Get-AzVmssVM -ResourceGroupName $vmss.ResourceGroupName -VMScaleSetName $vmss.Name
        
        if($vmsscount -eq 0 -or $vmsscount % 5 -eq 0){
            Write-Progress -Activity "VMSS Collection" -Status "$vmsscount of $($vmssList.Length)"
        }
        
        foreach($vmFromVmss in $vmListfromVmss){
            try{
            	$vmInfo = Get-AzVmssVM -ResourceGroupName $vmFromVmss.ResourceGroupName -VMScaleSetName $vmss.Name -InstanceID $vmFromVmss.InstanceID
							if(!$vmInfo){continue}
						}
						catch{
							ModuleLogMessage -message "Unable to execute Get-AzVmssVM. $_" -log $using:LogFile
						}

            $vmSizeInfo = Get-AzVMSize -Location $vmInfo.Location | Where-Object{$_.Name -eq $vmInfo.Sku.Name}
						if(!$vmSizeInfo){continue}

            $vmStatusInfo = Get-AzVmssVM -InstanceView -ResourceGroupName $vmFromVmss.ResourceGroupName -VMScaleSetName $vmss.Name -InstanceID $vmFromVmss.InstanceID
						if(!$vmStatusInfo){continue}
            
            $piptxt = ""
            $ipInfo = GetVssVmIpInfo $vmInfo $piptxt

            SetVmTags $vmInfo "ScaleSetName" $vmss.Name
            SetVmInfo $vmInfo $ipInfo $vmSizeInfo $vmStatusInfo $vmInfo.Sku.Name
            SetDiskInfo $vmInfo $vmStatusInfo
            
						#if enabled add vmss vm to perf collection array
            if(-Not $no_perf){
                $vmPerfIds = [PSCustomObject]@{
                    "vmID"   = $vmInfo.VmId
                    "rid"    = $vmInfo.Id
					"vmMem"  = $vmSizeInfo.MemoryInMb
                    }
                $vmPerfList += $vmPerfIds
            }
            $vmCount = $vmCount + 1
        }

        $vmsscount = $vmsscount +1
    }
    
	#Collect performance data using parallel processing option
    try{
		if(-Not $no_perf){
			Write-Progress -Activity "Performance Collection" -Status "$vmCount VMs"
			LogMessage("Perf Collection using $threadLimit threads")
			
			$returnPerfData = $vmPerfList | ForEach-Object -ThrottleLimit $threadLimit -Parallel {
				try{
					Import-Module "$(Get-Location)/get-performance-data.psm1"
					if($_){
						SetPerformanceInfo -ids $_ -log $using:LogFile 
					}
				}
				catch{
					ModuleLogMessage -message "Unable to collect performance data for vm. $_" -log $using:LogFile
				}
			}
			$global:vmPerfData += $returnPerfData
			
			$runningJobs = (Get-Job | Where-Object {($_.State -eq "Running") -or ($_.State -eq "NotStarted")}).count
			While($runningJobs -ne 0){
				$runningJobs = (Get-Job | Where-Object {($_.State -eq "Running") -or ($_.State -eq "NotStarted")}).count
			}
		}
	}
	catch{
		LogMessage("Error collecting performance. $_")
	}
}


Write-Host "VM Count: " $vmCount
LogMessage("VM Count: $vmCount")

#Measure-Command{}
# Writ all collected data to csv files
if($vmCount -gt 0){
	try{
		LogMessage("Write data to files")
		Write-Progress -Activity "Data Collection" -Status "Write to output files"
		if(-Not $no_resources){
			$resourceListlist | ConvertTo-Json | Set-Content "$global:outputPath\resources.json" -encoding utf8
		}

		$global:vmObjectList | Export-Csv -NoTypeInformation -Path "$global:outputPath\vmInfo.csv"
		$global:vmTagsList | Export-Csv -NoTypeInformation -Path "$global:outputPath\tagInfo.csv"
		$global:vmDisksList | Export-Csv -NoTypeInformation -Path "$global:outputPath\diskInfo.csv"
		if(-Not $no_perf){
			$global:vmPerfData | Export-Csv -NoTypeInformation -Path "$global:outputPath\perfInfo.csv"
		}
	}
	catch{
		Write-Host "Error writing output files" -ForegroundColor yellow
	}

	try{
		LogMessage("Compressing output files")
		Compress-Archive -Path "$outputPath\*.csv" -DestinationPath "$(Get-Location)\vm-azure-import-files.zip"
		if(-Not $no_resources){
			Compress-Archive -Path "$outputPath\*.json" -DestinationPath "$(Get-Location)\services-azure-import-files.zip"
		}
	}
	catch{
		Write-Host "Error compressing output files" -ForegroundColor yellow
	}
}

Write-Host "Collection Completed"
if($no_perf){
	write-host "No performance data collected"
}
if($no_public_ip){
	write-host "No public IP data collected"
}
if ($no_resources){
	write-host "Resource data was not collected"
}
				
LogMessage("Collection Completed")
