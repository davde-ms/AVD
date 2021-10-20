<#
.SYNOPSIS
  Set the 'SetDrainModeOn' tag to Yes on all VMs in a hostpool.
.DESCRIPTION
  Prepares all existing VMs in a hostpool for an update cycle (will be tagged for deletion)
.PARAMETER SubscriptionName
The subscription name
.PARAMETER HostPoolName
    The name of the host pool that contains the VMs you want to tag
.PARAMETER HostPoolResourceGroupName
  The name of the resource group that contains the Host Pool
.NOTES
  Version:        1.0
  Author:         David De Backer
  Creation Date:  2021-05-18

.EXAMPLE
 ./TagVMsforUpdate.ps1 -HostPoolName $HostPoolName
 Sets all hosts in the host pool with the tag 'SetDrainModeOn' to 'Yes'

#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName,

  [Parameter(mandatory = $true)]
  [string]$HostPoolName
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
    
    #if ($hybridWorkerName -ne "stvhyb-s001") getting replaced by registry key check
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

Select-AzSubscription $SubscriptionName
$hostPool = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' | Where-Object Name -eq $HostPoolName  | Select-Object Name, ResourceGroupName

#-----------------------------------------------------------[Functions]------------------------------------------------------------

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
    $VMName = ($SessionHost.Name -Split '/')[1]
    $vmName = ($VMName -Split '\.')[0]
       
    return $VMName
  }

function Tag-VMs {
    <#
      .SYNOPSIS
      Changes hosts drain mode according to the provided paramters.
      #>
      [CmdletBinding()]
      param (
        [Parameter(mandatory = $true)]
        [string]$HostPoolName
      )
    
    Write-Output "Starting the tagging process..."
    $success = 0
    $failed = 0
  
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $HostPoolName
    $total = ($sessionHosts).count
    $sessionHosts | Select-Object Name
    
    $hostsToProcess = $sessionHosts

    foreach ($sh in $hostsToProcess) {
      $Error.clear()
        
      $VMName = Get-VMNameFromSessionHost($sh)
      Write-Output "VMName = $VMName"
      $VM = Get-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" -Name $VMName
      $Tags = $VM.Tags
      $Tags += @{$tagName=$tagValue}
      $VM | Set-AzResource -Tag $Tags -Force
      
      if (!$Error[0]) {
        $success += 1
        Write-Output "Successfully set the tag on $VMName"
      }
      else {
        $failed += 1
        Write-Error "!! Failed to set the tag on $VMName !!"
      }
    }
    
        
    $outputObject = [PSCustomObject]@{
      TotalVMstoTag = $total
      TaggedVMsCount = $success
      TagFailedCount = $failed
    }

    return $outputObject

}

$outToLogicApp = Tag-VMs -HostPoolName $HostPoolName
Write-Output ( $outToLogicApp | ConvertTo-Json)
