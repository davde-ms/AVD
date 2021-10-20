<#
.SYNOPSIS
  Changes the drain mode setting on VMs in a hostpool.
.DESCRIPTION
  When SetDrainMode is set to on or ON, puts the VMs of a hostpool in drain mode. New users can no longer connect to them while Drain Mode is set to ON.
.PARAMETER SubscriptionName
The subscription name
.PARAMETER HostPoolName
    The name of the host pool that contains the VMs you either want to put in drain mode or remove the drain mode flag from.
.PARAMETER HostPoolResourceGroupName
  The name of the resource group that contains the Host Pool
.PARAMETER HostPoolResourceGroupName
  The RG containing the VMs of the Hostpool  
.PARAMETER SetDrainMode
  Sets the drain mode to On (prevents new sessions). If not set then sets drain mode to off (allows new sessions)
.NOTES
  Version:        1.0
  Author:         David De Backer
  Creation Date:  20210-05-13

.EXAMPLE
 ./SetDrainMode.ps1 -HostPoolName $HostPoolName -SetDrainMode $SetDrainMode
 Sets all hosts in the host pool to drain mode

.EXAMPLE
./SetDrainMode.ps1 -HostPoolName $HostPoolName 
 Sets 'Allow New Sessions' on all hosts in the host pool that are currently set to drain mode

 .EXAMPLE
./SetDrainMode.ps1 -HostPoolName $HostPoolName -SetDrainMode $SetDrainMode
 Sets drain mode on a specific host in the host pool that currently accepts new connections
#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName,

  [Parameter(mandatory = $true)]
  [string]$HostPoolName,

  [Parameter(mandatory = $true)]
  [string]$VMResourceGroupName,
  
  [Parameter(Mandatory = $false, HelpMessage = "When set to ON, sets the hosts in drain mode. If not set then drain mode is turned off whereever it's found to be on")]
  [string]$SetDrainMode
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
    
    #Checking whether the hybrid worker installation folder is present, if so assuming to run from an hybrid worker.
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

$hostPool = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' | Where-Object Name -eq $HostPoolName  | Select-Object Name, ResourceGroupName

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function GetTaggedVMs {
    <#
      .SYNOPSIS
      Gets all tagged VMs for Drain Mode and returns an array of VM Names
      #>
    
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



function Set-DrainMode 
{
    <#
      .SYNOPSIS
      Changes hosts drain mode according to the provided paramters.
      #>
      [CmdletBinding()]
      param (
        [Parameter(mandatory = $true)]
        [string]$HostPoolName,

        #[Parameter(mandatory = $false)]
        #[string]$VMResourceGroupName,
        
        [Parameter(Mandatory = $False, HelpMessage = "Sets drain mode on. If not set then drain mode is turned off whereever it's found to be on")]
        [string]$SetDrainMode
      )
    
    
    #Getting all hosts from the hostpool
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $HostPoolName
    $totalHosts = ($sessionHosts).count
    $sessionHosts | Select-Object Name, Status, Session, AllowNewSession | Out-Null

    #Retrieving the VMs tagged for update  
    $taggedVMs = GetTaggedVMs
    
    #Checking whether the drainmode paramter was set to On when starting the runbook
    if ($SetDrainMode -eq "on")
    {
        Write-Output "Putting hosts in drainmode"
        #Getting all hosts with drain mode OFF
        $hostsToProcess = $sessionHosts | Where-Object AllowNewSession -eq $true 
    }

    else
    {
        #Getting all hosts with drain mode ON
        $hostsToProcess = $sessionHosts | Where-Object AllowNewSession -eq $false    
    }
    
    foreach ($sh in $hostsToProcess)
    {
        $Error.clear()
        $hpHost = Get-VMNameFromSessionHost($sh)
        $thisAllowNewSessions = $sh.AllowNewSession
        $shHostName = $sh.Name.Split("/")[1]
            
        #If Drain Mode is set to On and we allow new sessions
        if ($SetDrainMode -eq "on" -and $thisAllowNewSessions)
        {
              $match = 0
              foreach ($vm in $taggedVMs) 
              {
                  Write-Output "vmName is $vm.Name"
                  #checking whether the host matches any of the tagged VMs names
                  if ($hpHost -eq $vm.Name)
                  {
                    $match +=1  
                  }  
              }
              #If we got a match we set the host to NO longer accept connections (drain)
              if ($match -gt 0)
              {
                  Update-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName `
                  -HostPoolName $HostPoolName `
                  -Name $shHostName `
                  -AllowNewSession:$false
                  
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

    #If Drain Mode is NOT set to ON and we don't already allow new sessions on the host
      elseif (! ($SetDrainMode -eq "on") -and ! $thisAllowNewSessions)
        {
          Update-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName `
          -HostPoolName $HostPoolName `
          -Name $shHostName `
          -AllowNewSession:$true  
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
      HostsDrainedSuccess = $success
      HostsDrainedFailure = $failed
      HostsSkippedCount = $totalHosts - ($success+$failed)
    }

    return $outputObject
}

$outToLogicApp = Set-DrainMode -HostPoolName $HostPoolName -SetDrainMode $SetDrainMode -verbose

Write-Output ( $outToLogicApp | ConvertTo-Json)
