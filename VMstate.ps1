Function Update-OperationalStatus {
        param(
            [Object]$VirtualMachine,
            [String]$OpValue
        )  
    #Define Variables
    $SNOWUsername = Get-AutomationVariable -Name "snow_username"
    $SNOWPassword = Get-AutomationVariable -Name "snow_password"
    $SNOWInstance = Get-AutomationVariable -Name "snow_instance"
    $SNOWURL = "https://$SNOWInstance.service-now.com/"

    #Create Header
    $HeaderAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $SNOWUsername, $SNOWPassword)))
    $SNOWSessionHeader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $SNOWSessionHeader.Add('Authorization',('Basic {0}' -f $HeaderAuth))
    $SNOWSessionHeader.Add('Accept','application/json')
    $Type = "application/json"

    $VMName = $VirtualMachine.Name
    #Create URL using VMNanme and grab ID of CI
    $QueryURL = $SNOWURL+"api/now/table/cmdb_ci?sysparm_query=nameLIKE" + $VMName
   
    Try 
    {
    $VMJson = Invoke-RestMethod -Method GET -Uri $QueryURL -TimeoutSec 100 -Headers $SNOWSessionHeader -ContentType $Type
    $VMJsonResult = $VMJson.result
    $VMID = $VMJsonResult.sys_id
    }
    Catch 
    {
    Write-Host $_.Exception.ToString()
    $error[0] | Format-List -Force
    }
    #Check that CI exists in CMDB
    If($VMID){
        #Create URL for Updating Operational status
        $QueryURL = $SNOWURL+"api/now/table/cmdb_ci/" + $VMid
        
        $OPStatusJson =
        "{
        ""operational_status"": ""$OpValue""
        }"
        # POST to API
        Try 
        {
        $CIPOSTResponse = Invoke-RestMethod -Method Patch -Uri $QueryURL -Body $OPStatusJson -TimeoutSec 100 -Headers $SNOWSessionHeader -ContentType $Type
        }
        Catch 
        {
        Write-Host $_.Exception.ToString()
        $error[0] | Format-List -Force
        }
    }else{
        Write-Output "CI Cannot be found in SNOW"
    }
}
$Simulate = Get-AutomationVariable -name "simulate_shutdown"
$runbookstarttime = (Get-Date).ToUniversalTime()
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

$azure_subscription_ids = $encryptvar = Get-AutomationVariable -Name "azure_subscription_ids"
$Sublist = $azure_subscription_ids.split(",")


function CheckScheduleEntry ([string]$TimeRange)
{	
	# Initialize variables
	$rangeStart, $rangeEnd, $parsedDay = $null
	$currentTime = (Get-Date).ToUniversalTime()
    $midnight = $currentTime.AddDays(1).Date	        

	try
	{
	    # Parse as range if contains '-'
	    if($TimeRange -like "*-*")
	    {
	        $timeRangeComponents = $TimeRange -split "-" | foreach {$_.Trim()}
	        if($timeRangeComponents.Count -eq 2)
	        {
	            $rangeStart = Get-Date $timeRangeComponents[0]
	            $rangeEnd = Get-Date $timeRangeComponents[1]
	
	            # Check for crossing midnight
	            if($rangeStart -gt $rangeEnd)
	            {
                    # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                    if($currentTime -ge $rangeStart -and $currentTime -lt $midnight)
                    {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise interpret start time as yesterday and end time as today   
                    else
                    {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
	            }
	        }
	        else
	        {
	            Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '-'" 
	        }
	    }
	    # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25' 
	    else
	    {
	        # If specified as day of week, check if today
	        if([System.DayOfWeek].GetEnumValues() -contains $TimeRange)
	        {
	            if($TimeRange -eq (Get-Date).DayOfWeek)
	            {
	                $parsedDay = Get-Date "00:00"
	            }
	            else
	            {
	                # Skip detected day of week that isn't today
	            }
	        }
	        # Otherwise attempt to parse as a date, e.g. 'December 25'
	        else
	        {
	            $parsedDay = Get-Date $TimeRange
	        }
	    
	        if($parsedDay -ne $null)
	        {
	            $rangeStart = $parsedDay # Defaults to midnight
	            $rangeEnd = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59) # End of the same day
	        }
	    }
	}
	catch
	{
	    # Record any errors and return false by default
	    Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> - <EndTime>', or days/dates like 'Sunday' and 'December 25'"   
	    return $false
	}
	
	# Check if current time falls within range
	if($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd)
	{
	    return $true
	}
	else
	{
	    return $false
	}
	
} # End function CheckScheduleEntry

# Function to handle power state assertion for resource manager VM

function AssertResourceManagerVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [bool]$Simulate
    )

    # Get VM with current status
    $resourceManagerVM = Get-AzureRmVM -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
    $currentStatus = $resourceManagerVM.Statuses | where Code -like "PowerState*" 
    $currentStatus = $currentStatus.Code -replace "PowerState/",""

    # If should be started and isn't, start VM
	if($DesiredState -eq "Started" -and $currentStatus -notmatch "running")
	{
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have started VM. (No action taken)"
        }
        else
        {
            Write-Output "[$($VirtualMachine.Name)]: Starting VM"
            $resourceManagerVM | Start-AzureRmVM
        }
	}
		
	# If should be stopped and isn't, stop VM
	elseif($DesiredState -eq "StoppedDeallocated" -and $currentStatus -ne "deallocated")
	{
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have stopped VM. (No action taken)"
        }
        else
        {
            Write-Output "[$($VirtualMachine.Name)]: Stopping VM"
            $resourceManagerVM | Stop-AzureRmVM -Force
        }
	}

    # Otherwise, current power state is correct
    else
    {
        Write-Output "[$($VirtualMachine.Name)]: Current power state [$currentStatus] is correct."
    }
}
# Function to handle power state assertion for both classic and resource manager VMs
function AssertVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [Object[]]$ResourceManagerVMList,
        [bool]$Simulate
    )   
        $resourceManagerVM = $ResourceManagerVMList | where Name -eq $VirtualMachine.Name
        AssertResourceManagerVirtualMachinePowerState -VirtualMachine $resourceManagerVM -DesiredState $DesiredState -Simulate $Simulate
}

foreach($sub in $Sublist){
    select-azurermsubscription -subscriptionid $sub


    # Main runbook content
    try
    {
        $currentTime = (Get-Date).ToUniversalTime()
        
        if($Simulate)
        {
            Write-Output "*** Running in SIMULATE mode. No power actions will be taken. ***"
        }
        else
        {
            Write-Output "*** Running in LIVE mode. Schedules will be enforced. ***"
        }
        Write-Output "Current UTC/GMT time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] will be checked against schedules"
        

    $resourceManagerVMList = @(Get-AzureRmResource | where {$_.ResourceType -like "Microsoft.*/virtualMachines"} | sort Name)
        

        # Get resource groups that are tagged for automatic shutdown of resources
        $taggedResourceGroups = @(Get-AzureRmResourceGroup | where {$_.Tags.Count -gt 0 -and $_.Tags.Name -contains "AutoShutdownSchedule"})
        $taggedResourceGroupNames = @($taggedResourceGroups | select -ExpandProperty ResourceGroupName)
        Write-Output "Found [$($taggedResourceGroups.Count)] schedule-tagged resource groups in subscription"	

        # For each VM, determine
        #  - Is it directly tagged for shutdown or member of a tagged resource group
        #  - Is the current time within the tagged schedule 
        # Then assert its correct power state based on the assigned schedule (if present)
        Write-Output "Processing [$($resourceManagerVMList.Count)] virtual machines found in subscription"
        foreach($vm in $resourceManagerVMList)
        {
            $schedule = $null

            # Check for direct tag or group-inherited tag
            if($vm.ResourceType -eq "Microsoft.Compute/virtualMachines" -and $vm.Tags -and $vm.Tags.Name -contains "AutoShutdownSchedule")
            {
                # VM has direct tag (possible for resource manager deployment model VMs). Prefer this tag schedule.
                $schedule = ($vm.Tags | where Name -eq "AutoShutdownSchedule")["Value"]
                Write-Output "[$($vm.Name)]: Found direct VM schedule tag with value: $schedule"
            }
            elseif($taggedResourceGroupNames -contains $vm.ResourceGroupName)
            {
                # VM belongs to a tagged resource group. Use the group tag
                $parentGroup = $taggedResourceGroups | where ResourceGroupName -eq $vm.ResourceGroupName
                $schedule = ($parentGroup.Tags | where Name -eq "AutoShutdownSchedule")["Value"]
                Write-Output "[$($vm.Name)]: Found parent resource group schedule tag with value: $schedule"
            }
            else
            {
                # No direct or inherited tag. Skip this VM.
                Write-Output "[$($vm.Name)]: Not tagged for shutdown directly or via membership in a tagged resource group. Skipping this VM."
                continue
            }

            # Check that tag value was succesfully obtained
            if($schedule -eq $null)
            {
                Write-Output "[$($vm.Name)]: Failed to get tagged schedule for virtual machine. Skipping this VM."
                continue
            }

            # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
            $timeRangeList = @($schedule -split "," | foreach {$_.Trim()})
            
            # Check each range against the current time to see if any schedule is matched
            $scheduleMatched = $false
            $matchedSchedule = $null
            foreach($entry in $timeRangeList)
            {
                if((CheckScheduleEntry -TimeRange $entry) -eq $true)
                {
                    $scheduleMatched = $true
                    $matchedSchedule = $entry
                    break
                }
            }

            # Enforce desired state for group resources based on result. 
            if($scheduleMatched)
            {
                # Schedule is matched. Shut down the VM if it is running. 
                Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule]"
                Update-OperationalStatus -VirtualMachine $vm -OpValue "2"
                AssertVirtualMachinePowerState -VirtualMachine $vm -DesiredState "StoppedDeallocated" -ResourceManagerVMList $resourceManagerVMList  -Simulate $Simulate
            }
            else
            {
                # Schedule not matched. Start VM if stopped.
                Write-Output "[$($vm.Name)]: Current time falls outside of all scheduled shutdown ranges."
                Update-OperationalStatus -VirtualMachine $vm -OpValue "1"
                AssertVirtualMachinePowerState -VirtualMachine $vm -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -Simulate $Simulate
            }	    
        }

        Write-Output "Finished processing virtual machine schedules"
    }
    catch
    {
        $errorMessage = $_.Exception.Message
        throw "Unexpected exception: $errorMessage"
    }
    finally
    {
        Write-Output "Subscription finished (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $currentTime))))"
    }
}
Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $runbookstarttime))))"
#>
