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


.PARAMETER no_perf
Default False. Use to indicate whether performance data will collected.

#>

# Version 1.2

[cmdletbinding()]
param (
  [switch]$no_perf=$false
)

$global:vmObjectList = @()
$global:vmTagsList = @()
$global:vmDisksList = @()
$global:vmPerfData = @()

$subList = Get-AzSubscription
$outputPath = "$(Get-Location)\output\"
$LogFile = "$outputPath\stratozone-azure-export.log"


$ipInfo = [PSCustomObject]@{
    publicIp     = ""
    primaryIp    = ""
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
    	Add-content $LogFile -value ((Get-Date).ToString() + " - " + $Message)
	}
	catch{
		Write-Host "Unable to Write to log file"
	}
}

# Divide the network data by the time period used in the query
function CalculateNetworkDataPerSec($NetworkTotal){
	try{
		return $NetworkTotal /1800
	}
	catch{
		Write-Host "Error calculating network perf data" -ForegroundColor yellow
		return 0
	}
}

#get disk info for dealicated VM
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
function SetDiskInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm,
		#vm Status info
		[Parameter(Mandatory = $true)]
		$vmStatusInfo
	)

	
	# collect info on all disks attached tot he VM
	# UsedInGib data is unavailable in Azure and it will be left empty.
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
			$diskSize = 52.5
		}

		$vmDataDisk = [pscustomobject]@{
				"MachineId"=$vm.VmId
				"DiskLabel"=$disk.Name
				"SizeInGib"=$diskSize 
				"UsedInGib"=""
				"StorageTypeLabel"=$diskType
			}

		$global:vmDisksList += $vmDataDisk
	}

	
	# Add OS disk to the list of disks for VM
	# UsedInGib data is unavailable in Azure and it will be left empty.
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
		$diskSize = 52.5
	}
	if([string]::IsNullOrWhiteSpace($diskType)){
		$diskType = "Standard_LRS"
	}

	$vmOsDisk = [pscustomobject]@{
		"MachineId"=$vm.VmId
		"DiskLabel"=$vm.StorageProfile.OSDisk.Name
		"SizeInGib"= $diskSize
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
		[Parameter(Mandatory = $true)]
		$vm,

		[Parameter(Mandatory = $false)]
		$tagKey,

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

#Add performance data to the global array for specified VM
function SetPerformanceInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$vm
	)

	$endTime = Get-Date
	$startTime = $endTime.AddDays(-30)
	
	$metricName = "Percentage CPU,Available Memory Bytes,Disk Read Operations/Sec,Disk Write Operations/Sec,Network Out Total,Network In Total"
	$vmMetric = Get-AzMetric -ResourceId $vm.Id -MetricName $metricName -EndTime $endTime -StartTime  $startTime -TimeGrain 0:30:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
	
	$perfDataCount = $vmMetric[0].Data.Count
	
	if($vmMetric.Count -gt 5){
		for($i =0;$i -lt $perfDataCount; $i++){
			try{
				$vmPerfMetrics = [pscustomobject]@{
					"MachineId"=$vm.VmId
					"TimeStamp"=$vmMetric[0].Data[$i].TimeStamp
					"CpuUtilizationPercentage"=$vmMetric[0].Data[$i].Average
					"AvailableMemoryBytes"=[math]::ceiling($vmMetric[1].Data[$i].Average)
					"DiskReadOperationsPerSec"=$vmMetric[2].Data[$i].Average
					"DiskWriteOperationsPerSec"=$vmMetric[3].Data[$i].Average
					"NetworkBytesPerSecSent"=CalculateNetworkDataPerSec($vmMetric[4].Data[$i].Total)
					"NetworkBytesPerSecReceived"=CalculateNetworkDataPerSec($vmMetric[5].Data[$i].Total)
					}
				$global:vmPerfData += $vmPerfMetrics
				}
			catch{
				LogMessage($_.Exception.Message)
			}
		}
		
	}
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

	foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
		$nicConfig = Get-AzResource -ResourceId $nic.Id 
		foreach($ipConfig in $nicConfig.Properties.IpConfigurations){
			$ipInfo.ipList = $ipInfo.ipList + $ipConfig.Properties.PrivateIpAddress + ";"
	
			if ([string]::IsNullOrWhiteSpace($ipInfo.primaryIp)){
				$ipInfo.primaryIp = $ipConfig.Properties.PrivateIpAddress
			}
		}
	}
	if(![string]::IsNullOrWhiteSpace($publicIp)){
		$ipInfo.ipList = $ipInfo.ipList + $publicIp + ";"
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

	foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
		$nicConfig = Get-AzResource -ResourceId $nic.Id | Get-AzNetworkInterface

		foreach($ipConfig in $nicConfig.IpConfigurations){
			$ipInfo.ipList = $ipInfo.ipList + $ipConfig.PrivateIpAddress + ";"

			foreach($pip in $ipConfig.PublicIpAddress){
				$pubIp = Get-AzResource -ResourceId $pip.id | Get-AzPublicIpAddress
				if($pubIp.IpAddress -ne "Not Assigned" -And ![string]::IsNullOrWhiteSpace($pubIp.IpAddress)){
					$ipInfo.publicIp = $pubIp.IpAddress 
					$ipInfo.ipList = $ipInfo.ipList + $pubIp.IpAddress + ";"
				}
			}
			
			if ([string]::IsNullOrWhiteSpace($ipInfo.primaryIp)){
				$ipInfo.primaryIp = $ipConfig.PrivateIpAddress
			}
		}
	}
	if($ipInfo.ipList.Length -gt 1){
		$ipInfo.ipList = $ipInfo.ipList.Substring(0,$ipInfo.ipList.Length -1)
	}

	return $ipInfo
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

	$vmBasicInfo = [pscustomobject]@{
		"MachineId"=$vm.VmId
		"MachineName"=$vm.Name
		"PrimaryIPAddress"=$ipInfo.primaryIp
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
		"CreateDate"=$vmStatusInfo.Statuses[0].Time
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
	}
}
catch{
		Write-Host "Error creating output directory" -ForegroundColor yellow
}


LogMessage("Starting collection script")
$vmCount = 0

# Loop through all subscriptions user has access to
foreach ($sub in $subList){
	LogMessage("Processing Subscription $sub.Name")

	Select-AzSubscription -SubscriptionId $sub.Id
	Set-AzContext -SubscriptionId $sub.Id

	
	$rgCount = 0
	$vmStatusInfo = $null
	$vmSizeInfo = $null

	$rgList = Get-AzResourceGroup 

	# Loop through all the resource groups in subscription
	foreach($rg in $rgList){
		$rgCount = $rgCount +1

		LogMessage("Processing Resource Group $($rg.ResourceGroupName)")

		$vmList = Get-AzVM -ResourceGroupName $rg.ResourceGroupName -Status -erroraction 'silentlycontinue'
		
		Write-Progress -Activity "Data Collection" -Status "Collecting Resource Group $rgCount of $($rgList.Length)"

		# Loop through all VMs in resource group
		foreach($vm in $vmList){
			$vmSizeInfo = Get-AzVMSize -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName | Where-Object{$_.Name -eq $vm.HardwareProfile.VmSize} -erroraction 'silentlycontinue'
			
			if(-Not $vmSizeInfo) {
				Write-Host "Error vmSizeInfo" -ForegroundColor yellow}
			
			$vmStatusInfo = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -erroraction 'silentlycontinue'
			if(-Not $vmStatusInfo) {
				Write-Host "Error vmStatusInfo" -ForegroundColor yellow}
			
			$ipInfo = GetVmIpinfo($vm)
			
			SetVmTags $vm
			SetVmInfo $vm $ipInfo $vmSizeInfo $vmStatusInfo $vm.HardwareProfile.VmSize
			SetDiskInfo $vm $vmStatusInfo
			if(-Not $no_perf){
				SetPerformanceInfo $vm
			}	
			$vmCount = $vmCount + 1
		}


		LogMessage("Processing Vmss")
		$vmssList = Get-AzVmss -ResourceGroupName $rg.ResourceGroupName -erroraction 'silentlycontinue'
		
		foreach($vmss in $vmssList){
			$vmListfromVmss = Get-AzVmssVM -ResourceGroupName $vmss.ResourceGroupName -VMScaleSetName $vmss.Name
			
			foreach($vmFromVmss in $vmListfromVmss){
				
				$vmInfo = Get-AzVmssVM -ResourceGroupName $vmFromVmss.ResourceGroupName -VMScaleSetName $vmss.Name -InstanceID $vmFromVmss.InstanceID
				$vmSizeInfo = Get-AzVMSize -Location $vmInfo.Location | Where-Object{$_.Name -eq $vmInfo.Sku.Name}
				$vmStatusInfo = Get-AzVmssVM -InstanceView -ResourceGroupName $vmFromVmss.ResourceGroupName -VMScaleSetName $vmss.Name -InstanceID $vmFromVmss.InstanceID
				
				$piptxt = ""
				$ipInfo = GetVssVmIpInfo $vmInfo $piptxt

				SetVmTags $vmInfo "ScaleSetName" $vmss.Name
				SetVmInfo $vmInfo $ipInfo $vmSizeInfo $vmStatusInfo $vmInfo.Sku.Name
				SetDiskInfo $vmInfo $vmStatusInfo
				if(-Not $no_perf){
					SetPerformanceInfo $vmInfo
				}
				$vmCount = $vmCount + 1
			}
		}

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

		$global:vmObjectList | Export-Csv -NoTypeInformation -Path "$outputPath\vmInfo.csv"
		$global:vmTagsList | Export-Csv -NoTypeInformation -Path "$outputPath\tagInfo.csv"
		$global:vmDisksList | Export-Csv -NoTypeInformation -Path "$outputPath\diskInfo.csv"
		if(-Not $no_perf){
			$global:vmPerfData | Export-Csv -NoTypeInformation -Path "$outputPath\perfInfo.csv"
		}
	}
	catch{
		Write-Host "Error writing output files" -ForegroundColor yellow
	}

	try{
		LogMessage("Compressing output files")
		Compress-Archive -Path "$outputPath\*.csv" -DestinationPath "$(Get-Location)\azure-import-files.zip"
	}
	catch{
		Write-Host "Error compressing output files" -ForegroundColor yellow
	}
}

Write-Host "Collection Completed"
if($no_perf){
	write-host "No performance data collected"
}
				
LogMessage("Collection Completed")