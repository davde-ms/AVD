<#Author       : David De Backer (based on a script by Akash Chawla)
# Usage        : Install and software package ABC
# This is a prototype script, not production ready
#>

###############
# Install ABC #
###############

Param (        
    [Parameter(Mandatory=$true)]
        [string]$packageZipNameURI
)

########################
# Variables Definition #
########################
$localDownloadPath            = "c:\temp\install\"
$packageZipName             = 'package.zip'


##############################
# Test/Create Temp Directory #
##############################
if((Test-Path c:\temp) -eq $false) {
    Write-Host "Package installation : Creating temp directory"
    New-Item -Path c:\temp -ItemType Directory
}
else {
    Write-Host "Package installation : C:\temp already exists"
}
if((Test-Path $localDownloadPath) -eq $false) {
    Write-Host "Package installation  : Creating directory: $localDownloadPath "
    New-Item -Path $localDownloadPath -ItemType Directory
}
else {
    Write-Host "Package installation : $localDownloadPath already exists"
}

####################
# Download Package #
####################
Write-Host "Package installation : Downloading package file from URI: $packageZipName"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $packageZipNameURI -OutFile "$localDownloadPath$packageZipName"


#################
# Unzip package #
#################
Write-Host "Package installation : Unzipping package installer"
Expand-Archive `
    -LiteralPath "$localDownloadPath$packageZipName" `
    -DestinationPath "$localDownloadPath\$packageZipName.Substring(0, $filename.LastIndexOf('.'))" `
    -Force `
    -Verbose

Set-Location $localDownloadPath 
Write-Host "Package installation : UnZip of $packageZipName.Substring(0, $filename.LastIndexOf('.')) complete"


###################
# Package Install #
###################
Write-Host "Package installation : Starting to install $packageZipName.Substring(0, $filename.LastIndexOf('.'))"
$package_deploy_status = Start-Process `
    -FilePath "$localDownloadPath\$packageZipName.Substring(0, $filename.LastIndexOf('.'))\fullpath_to_installer.exe_or_msi" `
    -ArgumentList "/install /quiet /norestart" `
    -Wait `
    -Passthru


#####################
# Registry Settings #
#####################

<# Write-Host "Package installation : Apply registry Settings, uncomment and use as example"
Push-Location 
Set-Location HKLM:\SOFTWARE\
New-Item `
    -Path HKLM:\SOFTWARE\FSLogix `
    -Name Profiles `
    -Value "" `
    -Force
New-Item `
    -Path HKLM:\Software\FSLogix\Profiles\ `
    -Name Apps `
    -Force
Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "Enabled" `
    -Type "Dword" `
    -Value "1"

Set-ItemProperty `
    -Path HKLM:\Software\FSLogix\Profiles `
    -Name "SIDDirNamePattern" `
    -Type String `
    -Value "%username%%sid%" #>


#Cleanup
if ((Test-Path -Path $localDownloadPath -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $localDownloadPath -Force -Recurse -ErrorAction Continue
}


#############
#    END    #
#############