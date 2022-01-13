<#
.SYNOPSIS
  Refreshes the hostpools tokens with fresh ones and stores them in a keyvault
.DESCRIPTION
  Enumerates the hostpools in the subscription, creates a new hostpool token and stores them in a keyvault.
.PARAMETER SubscriptionName
The subscription name
.NOTES
  Version:        1.0
  Author:         David De Backer
  Creation Date:  20210-05-13

#>

#---------------------------------------------------------[Script Parameters]------------------------------------------------------
[CmdletBinding()]
Param (
  [Parameter(mandatory = $true)]
  [string]$SubscriptionName

)

#---------------------------------------------------------[Initialisations]--------------------------------------------------------



# Setting the automation account properties we need to connect to our automation account
$keyVaultName = "replacewithkeyvaultname"
$tokenTTL = 3

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

Select-AzSubscription $SubscriptionName

$hostPoolsList = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostpools' | Select-Object Name, ResourceGroupName

Foreach ($hostPool in $hostPoolsList)
{
    #$hostPool = $hostPool -replace '\s+', ''
    Write-Output "Hostpool: " $hostPool.Name
    # Creating a new registration key
    New-AzWvdRegistrationInfo -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $hostPool.Name -ExpirationTime $((get-date).ToUniversalTime().AddDays($tokenTTL).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    # Extracting the registration key token
    $token = (Get-AzWvdRegistrationInfo -ResourceGroupName $hostPool.ResourceGroupName -HostPoolName $hostPool.Name).Token
    # Encoding the token as a secure string
    $secretvalue = ConvertTo-SecureString $token -AsPlainText -Force
    # Storing the token as a secret in the keyvault
    $tokenSecretName = $hostPool.Name + "-token"
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $tokenSecretName -SecretValue $secretvalue
}