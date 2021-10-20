<#
.SYNOPSIS
  Removes hosts from the hostpool and deletes matching VMs artifacts.
.DESCRIPTION
  Enumerates the hosts in a hostpool that are set to DENY new user connections and check the number of active connections.
  If no users are connected, removes the host from the hostpool and deletes the matching VMs artifacts (if the VM is tagged to be deleted).
.PARAMETER SubscriptionName
The subscription name
.PARAMETER HostPoolName
    The name of the host pool that you want to target.
.PARAMETER VMResourceGroupName
    The name RG containing the VMs of that hostpool.
.NOTES
  Version:        1.0
  Author:         David De Backer
  Creation Date:  20210-06-16

#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName,

  [Parameter(mandatory = $true)]
  [string]$HostPoolName,

  [Parameter(mandatory = $true)]
  [string]$VMResourceGroupName
)

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = 'Continue'
$verbosePreference = 'Continue'

#Initialize variables
$totalHosts = 0
$success = 0
$failed = 0
$tagName = "SetDrainModeOn"
$tagValue = "Yes"

# Start of Authentication Block
# =============================
 
# Ensuring we do not inherit an AzContext in our runbook
Disable-AzContextAutosave –Scope Process
 
#Getting the hybrid worker hostname
$workerName = hostname
$connectionName = "AzureRunAsConnection"
 
# Wrapping authentication in retry logic for potential transient failures
$logonAttempt = 0
while(!($servicePrincipalConnection) -and ($logonAttempt -le 10))
 
{
    $LogonAttempt++
    # Logging in to Azure...
    
    If (!(Test-Path "C:\Program Files\\Microsoft Monitoring Agent\Agent\AzureAutomation\*\HybridAgent"))
    {
        Write-Output "Job started from Azure worker $workerName."
                 
        try {
                $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName         
            
                "Logging in to Azure..."
                Connect-AzAccount `
                -ServicePrincipal `
                -TenantId $servicePrincipalConnection.TenantId `
                -ApplicationId $servicePrincipalConnection.ApplicationId `
                -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
                | Out-Null
            }
        catch   {
                    if (!$servicePrincipalConnection) {
                    $ErrorMessage = "Connection $connectionName not found."
                    throw $ErrorMessage
                }
        else    {
                    Write-Error -Message $_.Exception
                    throw $_.Exception
                }
          }
 
    }
    Else {
        Write-Output "Job started from hybrid worker $workerName."
        # Authenticating using the managed identity
        $servicePrincipalConnection = Connect-AzAccount -Identity #| Out-Null
    }
    Start-Sleep -Seconds 10
}

#End of Authentication Block
# ==========================

Select-AzSubscription $SubscriptionName | Out-Null

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function GetTaggedVMs {
    <#
      .SYNOPSIS
      Gets all tagged VMs for Drain Mode and returns an array of VM Names
      #>

      Param (
        [Parameter(mandatory = $true)]
        [string]$VMResourceGroupName
)
    
    $taggedVMs = Get-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" -TagName $tagName -TagValue $tagValue `
    | Where-Object ResourceGroupName -eq $VMResourceGroupName `
    | Select-Object Name   
    return $taggedVMs
}


function Get-VMNameFromSessionHost {
    <#
      .SYNOPSIS
      Extracts the VM Name from the full SessionHost name returned in the SessionHost object
      #>
    [CmdletBinding()]
    param (
      $SessionHost
    )
    #Name is in the format 'hostpoolname/vmname.domainfqdn' so need to split the last part
    $vmName = ($SessionHost.Name -Split '/')[1]
    $vmName = ($vmName -Split '\.')[0]
     
    return $vmName
}

function Remove-VMObjects {
    <#
      .SYNOPSIS
      Deletes the  matching VM and its related objects.
      #>
      [CmdletBinding()]
      param (
        [Parameter(mandatory = $true)]
        [string]$vmName,
        [Parameter(mandatory = $true)]
        [string]$VMResourceGroupName
      )
    
    $vmRGName = $VMResourceGroupName
    $vm = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $vmName
    
    #Marking OSDisk for deletion.
    $tags = @{"VMName"=$vm.Name; "Delete Ready"="Yes"}
    $osDiskName = $vm.StorageProfile.OSDisk.Name
    $datadisks = $vm.StorageProfile.DataDisks
    $ResourceID = (Get-Azdisk -Name $osDiskName).id
    New-AzTag -ResourceId $ResourceID -Tag $tags #| Out-Null
     
    #Marking Data disk(s) for deletion.
    if ($vm.StorageProfile.DataDisks.Count -gt 0) {
        foreach ($datadisks in $vm.StorageProfile.DataDisks) {
            $datadiskname=$datadisks.name
            $ResourceID = (Get-Azdisk -Name $datadiskname).id
            New-AzTag -ResourceId $ResourceID -Tag $tags | Out-Null
        }
    }
    
    Write-Output "Removing Virtual Machine $vm.Name in Resource Group $vmRGName."
    $null = $vm | Remove-AzVM -Force
    
    #Removing Network Interface Cards, Public IP Address(s) used by the VM...'
    foreach($nicUri in $vm.NetworkProfile.NetworkInterfaces.Id) {
        $nic = Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name $nicUri.Split('/')[-1]
        Remove-AzNetworkInterface -Name $nic.Name -ResourceGroupName $vm.ResourceGroupName -Force
        foreach($ipConfig in $nic.IpConfigurations) {
            if($ipConfig.PublicIpAddress -ne $null) {
                Remove-AzPublicIpAddress -ResourceGroupName $vm.ResourceGroupName -Name $ipConfig.PublicIpAddress.Id.Split('/')[-1] -Force
            }
        }
    }
    
    #Removing OS disk and Data Disk(s) used by the VM.
    Get-AzResource -tag $tags | Where-Object Resourcegroupname -eq $vmRGName | Remove-AzResource -force
  
  }

function Remove-Host {
    <#
      .SYNOPSIS
      Remove the hosts that are in drain mode and have no active user sessions.
      #>
      [CmdletBinding()]
      param (
        [Parameter(mandatory = $true)]
        [string]$HostPoolName,
        [Parameter(mandatory = $true)]
        [string]$VMResourceGroupName
      )
        
    #Getting a reference to the matching hostpool
    $hostPool = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' | Where-Object Name -eq $HostPoolName  | Select-Object Name, ResourceGroupName
    #Getting the sessionhosts matching the hostpool name where we DENY new connections
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $HostPoolName | Where-Object AllowNewSession -eq $false
    #Getting a count of sessionhosts where we DENY new connections
    $totalHosts = ($sessionHosts).count
    #Getting sessionhosts with an active session count of 0 (no users connected)
    $hostsToProcess = $sessionHosts | Where-Object Session -eq 0

    #Retrieving the VMs tagged for update  
    $taggedVMs = GetTaggedVMs -VMResourceGroupName $VMResourceGroupName
        
    #Looping through our host list
    foreach ($sh in $hostsToProcess) {
        $Error.clear()
        $hpHost = Get-VMNameFromSessionHost($sh)
        Write-Output "hpHost is $hpHost"
        $shHostName = $sh.Name.Split("/")[1]
        Write-Output "shHostName is $shHostName"
        

        $match = 0
        foreach ($vm in $taggedVMs) {
            Write-Output "vmName is $vm.Name"
            #checking whether the host matches any of the tagged VMs names
            if ($hpHost -eq $vm.Name) {$match +=1}  
        }

        #If we got a match we set to proceed with the host removal as well as the deletion of the matching VM artifacts
        if ($match -gt 0) {
            Remove-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $HostPoolName -Name $shHostName
            Remove-VMObjects -vmName $hpHost -VMResourceGroupName $VMResourceGroupName
            
            if (!$Error[0])
            {
                $success += 1
            }
            else
            {
                $failed += 1
            }
        }
    }

    $outputObject = [PSCustomObject]@{
      HostPoolName = $HostPoolName
      TotalHosts = $totalHosts
      ProcessedHosts = ($hostsToProcess).count
      HostsDeletedSuccess = $success
      HostsDeletedFailure = $failed
    }

    return $outputObject
}

$outToLogicApp = Remove-Host -HostPoolName $HostPoolName -VMResourceGroupName $VMResourceGroupName

Write-Output ( $outToLogicApp | ConvertTo-Json)
