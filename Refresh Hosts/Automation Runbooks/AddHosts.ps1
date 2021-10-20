<#
.SYNOPSIS
  Adds AVD host VMs based on an ARM template and a parameter file.
.DESCRIPTION
  Adds AVD host VMs based on an ARM template and a parameter file.
.PARAMETER SubscriptionName
The subscription name your hostpool and VMs are in.
.PARAMETER hostpoolName
The hostpool you would like to add VMs/hosts to.
.PARAMETER VMResourceGroupName
The resource group containing the VMS for the hostpool.
.PARAMETER vmCount
  The number of VMs you want to create. If not supplied, will add a number of VMs matching the number of VMs to be replaced.  
.PARAMETER vmStartSuffix
  The starting number of the VM suffix sequence. If not supplied will work in a 'flip/flop' mode where
  if last VM number is less than 500, it will start at 501, if more then 500 it will start at 1
.NOTES
  Version:        1.0
  Author:         David De Backer
  Creation Date:  20210-06-16

.EXAMPLE
 
#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName,
  
  [Parameter(mandatory = $true)]
  [string]$hostpoolName,

  [Parameter(mandatory = $true)]
  [string]$VMResourceGroupName,

  [Parameter(mandatory = $false)]
  [string]$vmCount,

  [Parameter(mandatory = $false)]
  [string]$vmStartSuffix
)

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = 'Continue'
$verbosePreference = 'Continue'

#Initialize variables
$totalHosts = 0
$totalVMsCreated = 0
$vmCount = 0
$vmStartSuffix = 0
$tagName = "SetDrainModeOn"
$tagValue = "Yes"
$StorageAccountName = "stcwvdinfraterraform"
$container_name = "host-pools"
$vmTemplateBlob = "addSH.json"
$templateLocalDir = "C:\DeployHosts"

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
$SubscriptionID = (Get-AzContext).Subscription.Id

function GetTaggedVMs {
    <#
      .SYNOPSIS
      Gets all tagged VMs for Drain Mode and returns an array of VM Names
      #>
    
    $taggedVMs = @(Get-AzResource -ResourceType "Microsoft.Compute/VirtualMachines" `
    -TagName $tagName `
    -TagValue $tagValue `
    | Where-Object ResourceGroupName -eq $VMResourceGroupName `
    | Select-Object Name)
    
    return $taggedVMs
  }

$hostPool = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' | Where-Object Name -eq $HostPoolName  | Select-Object Name, ResourceGroupName
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $HostPoolName
$totalHosts = ($sessionHosts).count

$StorageContext = New-AzStorageContext $StorageAccountName
$vmTemplateParamsBlob = "$HostPoolName.parameters.json"
$currentTime = (Get-Date).tostring(“dd-MM-yyyy-HH-mm”)
$deploySourceDir = New-Item -itemType Directory -Path $templateLocalDir -Name "$HostPoolName-$currentTime" -Force

$templateFile = Get-AzStorageBlobContent -Blob $vmTemplateBlob -Container $container_name -Destination "$deploySourceDir\vmdeploy.json" -Context $StorageContext -Force
$paramsFile = Get-AzStorageBlobContent -Blob $vmTemplateParamsBlob -Container $container_name -Destination "$deploySourceDir\vmparams.json" -Context $StorageContext -Force

$contents = Get-Content -Path "$deploySourceDir\vmparams.json"

#getting the last VMs in the hospool
$taggedVMs = GetTaggedVMs
$lastVM = $taggedVMs | Sort-Object -Property "Name" | Select -Last 1
$lastVMNumber = [int](($lastVM -Split '-')[2].Substring(0,3))
if ($lastVMNumber -lt 500) {$vmStartNumber = 501} else {$vmStartNumber = 1}

$jsonData = $contents | ConvertFrom-JSON
$jsonData.parameters.vmCount.value = $totalHosts
$jsonData.parameters.vmStartNumber.value = $vmStartNumber
$jsonData | ConvertTo-Json -Depth 10 | Out-File "$deploySourceDir\newparams.json"

New-AzResourceGroupDeployment -ResourceGroupName $VMResourceGroupName -TemplateFile "$deploySourceDir\vmdeploy.json" -TemplateParameterFile "$deploySourceDir\newparams.json"



