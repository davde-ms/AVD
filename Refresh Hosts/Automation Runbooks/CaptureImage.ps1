<#
.SYNOPSIS
  Captures a virtual machine image and stores it as a new version of an image definition in a Compute Gallery
.DESCRIPTION
  Captures a VM to a gallery image definition
.PARAMETER SubscriptionName
The subscription name your hostpool and VMs are in.
.PARAMETER VMResourceGroupName
The resource group containing the VM that you want to capture.
.PARAMETER VMName
The name of the VM that you want to capture.
.PARAMETER CIGName
The Compute Image Gallery Name you would like to capture to
.PARAMETER CIGResourceGroupName
The Compute Image Gallery resource group name you would like to capture to
.PARAMETER CIGImageDefinitionName
The Compute Image Gallery Image Definition name you would like to capture to
.PARAMETER CIGImageVersion
The version of Image Definition name you want to capture
.PARAMETER CIGImageRegions
The regions you want to push/replicate the image to

.NOTES
  Version:        0.1
  Author:         David De Backer
  Creation Date:  2022-05-02

.EXAMPLE
 
#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName,
  
  [Parameter(mandatory = $true)]
  [string]$VMName,

  [Parameter(mandatory = $true)]
  [string]$VMResourceGroupName,

  [Parameter(mandatory = $true)]
  [string]$CIGName,

  [Parameter(mandatory = $true)]
  [string]$CIGResourceGroupName,

  [Parameter(mandatory = $true)]
  [string]$CIGImageDefinitionName,

  [Parameter(mandatory = $true)]
  [string]$CIGImageVersion,

  [Parameter(mandatory = $false)]
  [string]$CIGImageRegions


)

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = 'Continue'
$verbosePreference = 'Continue'

#Initialize variables
$CIGResourceGroupName = "myResourceGroup"
$CIGName = "myGallery"
$CIGImageDefinitionName = "myImage"
$CIGImageVersion = "1.0.0"

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


$CIGResourceGroupName = "rg_SID"
$CIGName = "WVD_Gallery"
$CIGImageDefinitionName = "Win10-20H2"
$CIGImageVersion = "1.0.0"

Get-AzGalleryImageVersion -GalleryName $CIGName -ResourceGroupName $CIGResourceGroupName -GalleryImageDefinitionName $CIGImageDefinitionName | Select-Object -Property id | Format-List


$sourceImageId = "/subscriptions/$SubscriptionID/resourceGroups/$VMResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VMName"
New-AzGalleryImageVersion -ResourceGroupName $CIGResourceGroupName -GalleryName $CIGName -GalleryImageDefinitionName $CIGImageDefinitionName -Name $CIGImageVersion -Location $location -SourceImageId $sourceImageId