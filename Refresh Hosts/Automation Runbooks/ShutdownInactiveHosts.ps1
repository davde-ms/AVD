<#
.SYNOPSIS
  Shuts down hosts that have no active connections in a specified hostpool.
.DESCRIPTION
  Enumerates the hosts in a hostpool that have no active user connections.
  If no users are connected, shuts down the related VM.
.PARAMETER SubscriptionName
The subscription name
.PARAMETER HostPoolName
    The name of the host pool that you want to target.
.PARAMETER VMResourceGroupName
    The name of the RG containing the VMs for that hostpool.
.NOTES
  Version:        0.1
  Author:         David De Backer
  Creation Date:  2022-05-10

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
function ShutdownVM {
    <#
      .SYNOPSIS
      Shuts down the hosts that have no active user sessions.
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
    $hostpoolVMs = Get-AzVM -VMResourceGroupName $VMResourceGroupName -Status | Select-Object Name, PowerState
        
    #Looping through our host list
    foreach ($sh in $hostsToProcess) {
        $Error.clear()
        $hpHost = Get-VMNameFromSessionHost($sh)
        Write-Output "hpHost is $hpHost"
                
        foreach ($vm in $hostpoolVMs) {
            Write-Output "vmName is $vm.Name"
            #checking whether the host matches any of the VMs names
            if ($hpHost -eq $vm.Name) {

                Stop-AzVM -ResourceGroupName $VMResourceGroupName -Name $vm.Name -Force
            
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
        
    }

    $outputObject = [PSCustomObject]@{
      HostPoolName = $HostPoolName
      TotalHosts = $totalHosts
      ProcessedHosts = ($hostsToProcess).count
      VMStoppedSuccess = $success
      VMStoppedFailure = $failed
    }

    return $outputObject
}

$outToLogicApp = ShutdownVM -HostPoolName $HostPoolName -VMResourceGroupName $VMResourceGroupName

Write-Output ( $outToLogicApp | ConvertTo-Json)
