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

# Version 1.0

$vmObjectList = @()
$vmTagsList = @()
$vmDisksList = @()
$vmPerfData = @()

$subList = Get-AzSubscription
$outputPath = "$(Get-Location)\output\"
$LogFile = "$outputPath\stratozone-azure-export.log"


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

# Loop through all subscriptions user has access to
foreach ($sub in $subList){
	LogMessage("Processing Subscription $sub.Name")

	Select-AzSubscription -SubscriptionId $sub.Id
	Set-AzContext -SubscriptionId $sub.Id

	$vmCount = 0
	$rgCount = 0
	$vmStatusInfo = $null
	$vmSizeInfo = $null

	$rgList = Get-AzResourceGroup 

	# Loop through all the resource groups in subscription
	foreach($rg in $rgList){
		$rgCount = $rgCount +1

		LogMessage("Processing Resource Group $($rg.ResourceGroupName)")

		$vmList = Get-AzVM -ResourceGroupName $rg.ResourceGroupName -Status -erroraction 'silentlycontinue'
		
		LogMessage("VM Count  $($vmList.Length)")
		Write-Progress -Activity "Data Collection" -Status "Collecting Resource Group $rgCount of $($rgList.Length)"

		# Loop through all VMs in resource group
		foreach($vm in $vmList){
			
			try{
				$vmSizeInfo = Get-AzVMSize -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName | Where-Object{$_.Name -eq $vm.HardwareProfile.VmSize} -erroraction 'silentlycontinue'
			}
			catch{
				Write-Host "Error vmSizeInfo" -ForegroundColor yellow
			}

			try{
				$vmStatusInfo = Get-AzVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -erroraction 'silentlycontinue'
			}
			catch{
				Write-Host "Error vmStatusInfo" -ForegroundColor yellow
			}

			#Collect IP information
			$primaryIp = ""
			$ipList = ""
			$piptxt = ""

			foreach($nic in $vm.NetworkProfile.NetworkInterfaces){
				$nicConfig = Get-AzResource -ResourceId $nic.Id | Get-AzNetworkInterface
				foreach($ipConfig in $nicConfig.IpConfigurations){
					$ipList = $ipList + $ipConfig.PrivateIpAddress + ";"

					foreach($pip in $ipConfig.PublicIpAddress){
						$pubIp = Get-AzResource -ResourceId $pip.id | Get-AzPublicIpAddress
						$piptxt = $pubIp.IpAddress 
						$ipList = $ipList + $piptxt + ";"
					}
					
					if ($primaryIp -eq ""){
						$primaryIp = $ipConfig.PrivateIpAddress
					}
				}
			}
			if($ipList.Length -gt 1){
				$ipList = $ipList.Substring(0,$ipList.Length -1)
			}
			
			# TotalDiskAllocatedGiB and TotalDiskUsedGiB are used for manual entry and will be empty when collecting using scripts
			$vmBasicInfo = [pscustomobject]@{
				"MachineId"=$vm.VmId
				"MachineName"=$vm.Name
				"PrimaryIPAddress"=$primaryIp
				"PublicIPAddress"=$piptxt
				"IpAddressListSemiColonDelimited"=$ipList
				"TotalDiskAllocatedGiB"=""
				"TotalDiskUsedGiB"=""
				"MachineTypeLabel"=$vm.HardwareProfile.VmSize
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
			$vmObjectList += $vmBasicInfo

			# collect all tags assigned to VM
			foreach($key in $vm.Tags.Keys){
				$vmTags = [pscustomobject]@{
					"MachineId"=$vm.VmId
					"Key"= $key
					"Value"= $vm.Tags[$key]		
				}
				$vmTagsList += $vmTags
			}

			# collect info on all disks attached tot he VM
			# UsedInGib data is unavailable in Azure and it will be left empty.
			foreach($disk in $vm.StorageProfile.DataDisks){
				$vmDataDisk = [pscustomobject]@{
					"MachineId"=$vm.VmId
					"DiskLabel"=$disk.Name
					"SizeInGib"=$disk.DiskSizeGB
					"UsedInGib"=""
					"StorageTypeLabel"=$disk.ManagedDisk.StorageAccountType
				}
				$vmDisksList += $vmDataDisk
			}
			
			# Add OS disk to the list of disks for VM
			# UsedInGib data is unavailable in Azure and it will be left empty.
			$vmOsDisk = [pscustomobject]@{
				"MachineId"=$vm.VmId
				"DiskLabel"=$vm.StorageProfile.OSDisk.Name
				"SizeInGib"=$vm.StorageProfile.OSDisk.DiskSizeGB
				"UsedInGib"=""
				"StorageTypeLabel"=$vm.StorageProfile.OSDisk.ManagedDisk.StorageAccountType
			}
			$vmDisksList += $vmOsDisk

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
						$vmPerfData += $vmPerfMetrics
					 	}
					catch{
						LogMessage($_.Exception.Message)
					}
				}
				
			}
				
			$vmCount = $vmCount + 1
		}
	}
}

Write-Host "VM Count: " $vmCount
LogMessage("VM Count: $vmCount")

# Writ all collected data to csv files
if($vmCount -gt 0){
	try{
		LogMessage("Write data to files")
		Write-Progress -Activity "Data Collection" -Status "Write to output files"

		$vmObjectList | Export-Csv -NoTypeInformation -Path "$outputPath\vmInfo.csv"
		$vmTagsList | Export-Csv -NoTypeInformation -Path "$outputPath\tagInfo.csv"
		$vmDisksList | Export-Csv -NoTypeInformation -Path "$outputPath\diskInfo.csv"
		$vmPerfData | Export-Csv -NoTypeInformation -Path "$outputPath\perfInfo.csv"
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
LogMessage("Collection Completed")