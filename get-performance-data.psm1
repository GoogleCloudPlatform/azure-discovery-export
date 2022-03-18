#Add performance data to the global array for specified VM
function SetPerformanceInfo{
	param
	(
		# VM 
		[Parameter(Mandatory = $true)]
		$ids
	)
    $vmPerfObjectList = @()
	$endTime = Get-Date
	$startTime = $endTime.AddDays(-30)
	
	$metricName = "Percentage CPU,Available Memory Bytes,Disk Read Operations/Sec,Disk Write Operations/Sec,Network Out Total,Network In Total"
	$vmMetric = Get-AzMetric -ResourceId $ids.rid -MetricName $metricName -EndTime $endTime -StartTime  $startTime -TimeGrain 0:30:00 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
	
    if(-not $vmMetric){
        $vmPerfMetrics = [pscustomobject]@{
            "MachineId"=$ids.vmID
            "TimeStamp"=Get-Date -format "MM/dd/yyyy HH:mm:ss"
            "CpuUtilizationPercentage"=0
            "AvailableMemoryBytes"=0
            "DiskReadOperationsPerSec"=0
            "DiskWriteOperationsPerSec"=0
            "NetworkBytesPerSecSent"=0
            "NetworkBytesPerSecReceived"=0
            }
        $vmPerfObjectList += $vmPerfMetrics
        return $vmPerfObjectList
    }

	$perfDataCount = $vmMetric[0].Data.Count
	if($vmMetric.Count -gt 5){
		for($i =0;$i -lt $perfDataCount; $i++){
			try{
				$vmPerfMetrics = [pscustomobject]@{
					"MachineId"=$ids.vmID
					"TimeStamp"=$vmMetric[0].Data[$i].TimeStamp
					"CpuUtilizationPercentage"=[math]::Round($vmMetric[0].Data[$i].Average,10)
					"AvailableMemoryBytes"=[math]::ceiling($vmMetric[1].Data[$i].Average)
					"DiskReadOperationsPerSec"=[math]::Round(([decimal]$vmMetric[2].Data[$i].Average),10)
					"DiskWriteOperationsPerSec"=[math]::Round([decimal]$vmMetric[3].Data[$i].Average,10)
					"NetworkBytesPerSecSent"=CalculateNetworkDataPerSec([decimal]$vmMetric[4].Data[$i].Total)
					"NetworkBytesPerSecReceived"=CalculateNetworkDataPerSec([decimal]$vmMetric[5].Data[$i].Total)
					}
				$vmPerfObjectList += $vmPerfMetrics
				}
			catch{
                Write-Error $_.Exception.Message
			}
		}
		return $vmPerfObjectList
	}
}


# Divide the network data by the time period used in the query
function CalculateNetworkDataPerSec($NetworkTotal){
	try{
		return [math]::Round($NetworkTotal /1800,10)
	}
	catch{
		Write-Host "Error calculating network perf data" -ForegroundColor yellow
		return 0
	}
}


Export-ModuleMember -Function SetPerformanceInfo