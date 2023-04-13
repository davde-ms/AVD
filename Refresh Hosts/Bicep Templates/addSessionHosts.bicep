param location string = resourceGroup().location

@description('Tags for cost allocation')
param customTags1 object

@description('Number of hosts that will be created and added to the hostpool.')
param vmCount int

@maxLength(11)
@description('This prefix will be used in combination with the VM number to create the VM name. This value should only includes letters and NOT the dash, so if using “vm” as the prefix, VMs would be named “vm-0”, “vm-1”, etc. You should use a unique prefix to reduce name collisions in Active Directory.')
param vmPrefix string

@description('This number will be added the VM count to create the VM name. If you want to start your vms with number 10 you would set it to 10, so if using “vm” as the prefix, VMs names would begin at “vm-11”, “vm-12”, etc... You should use vmStartNumber when you have an existing set of vms and want to add new vms to that pool.')
param vmStartNumber int

@description('The size of the session host VMs.')
param vmSize string

@description('The username for the admin.')
param localAdminUsername string

@description('The password that corresponds to the existing domain username.')
@secure()
param localAdminPassword string

param useSIG bool

@description('RG name of the Azure SIG')
param SIG_rg string

@description('The name of the Azure SIG for your images.')
param SIGName string

@description('Defnition of the image to use from SIG.')
param SIGDefinition string

@description('The VM disk type for the VM: HDD or SSD.')
@allowed([
  'Premium_LRS'
  'StandardSSD_LRS'
  'Standard_LRS'
])
param diskType string

@description('Size of the OS disk.')
param osDiskSize int = 128

@description('The availability option for the VMs.')
@allowed([
  'None'
  'AvailabilitySet'
  'AvailabilityZone'
])
param availabilityOption string

@maxLength(9)
@description('The name of avaiability set to be used when create the VMs.')
param availabilitySetName string

@description('Set to true if you want to AAD Join, false if AD join')
param aadJoin bool = true

@description('IMPORTANT: Please don\'t use this parameter as intune enrollment is not supported yet. True if intune enrollment is selected.  False otherwise')
param intune bool = false

@description('Domain to join')
param domain string

@description('OU Path in standard LDAP format, ie: OU=name,DC=something,DC=com')
param OUPath string

@description('Admin account username.')
param domainJoinerUPN string

@description('Admin account password for domain join.')
@secure()
param domainJoinerPassword string

@description('The base URI where artifacts required by this template are located.')
param artifacts_location string

@description('The name of the hostpool.')
param hostpoolName string

@description('The token for adding VMs to the hostpool.')
@secure()
param hostpoolToken string

param systemData object = {}

@description('The unique id of the subnet to attach the NICs to.')
param subnetName string

@description('The resource id of the virtual network.')
param vNetId string

@description('The status of the auto-shutdown schedule.')
param autoShutdownStatus string

@description('The shutdown time.')
param autoShutdownTime string

@description('The Time Zone to use for autoShutdownTime.')
param autoShutdownTimeZone string

var subnetId = '${vNetId}/subnets/${subnetName}'
var sharedGalleryImageRef = {
  id: resourceId(SIG_rg, 'Microsoft.Compute/galleries/images', SIGName, SIGDefinition)
}
var win10ImageRef = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'Windows-11'
  sku: 'win11-22h2-avd'
  version: 'latest'
}
var vmAvailabilitySetResourceId = {
  id: resourceId('Microsoft.Compute/availabilitySets/', availabilitySetName)
}

resource compute 'Microsoft.Compute/virtualMachines@2021-03-01' = [for i in range(0, vmCount): {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}'
  location: location
  tags: customTags1
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    availabilitySet: ((availabilityOption == 'AvailabilitySet') ? vmAvailabilitySetResourceId : json('null'))
    osProfile: {
      computerName: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}'
      adminUsername: localAdminUsername
      adminPassword: localAdminPassword
    }
    storageProfile: {
      imageReference: (useSIG ? sharedGalleryImageRef : win10ImageRef)
      osDisk: {
        name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}-disk'
        createOption: 'FromImage'
        diskSizeGB: osDiskSize
        managedDisk: {
          storageAccountType: diskType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: resourceId('Microsoft.Network/networkInterfaces', '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}-nic')
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
    licenseType: 'Windows_Client'
  }
  zones: [
    ((availabilityOption == 'AvailabilityZone') ? string((((i + 0) % 3) + 1)) : json('null'))
  ]
  dependsOn: [
    nic
  ]
}]

resource nic 'Microsoft.Network/networkInterfaces@2018-10-01' = [for i in range(0, vmCount): {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}]

resource shutdown 'Microsoft.DevTestLab/schedules@2017-04-26-preview' = [for i in range(0, vmCount): {
  name: 'shutdown-computevm-${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}'
  location: location
  properties: {
    status: autoShutdownStatus
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    targetResourceId: resourceId('Microsoft.Compute/virtualMachines', '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}')
  }
  dependsOn: [
    compute
  ]
}]

resource aadjoin 'Microsoft.Compute/virtualMachines/extensions@2021-07-01' = [for i in range(0, vmCount): if (aadJoin) {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/aadjoin'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: intune ? {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    } : {}
  }
  dependsOn: [
    compute
  ]
}]

resource vmPrefix_vmStartNumber_3_0_joindomain 'Microsoft.Compute/virtualMachines/extensions@2022-08-01' = [for i in range(0, vmCount): if (!aadJoin) {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/joindomain'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      name: domain
      ouPath: OUPath
      user: domainJoinerUPN
      restart: 'true'
      options: '3'
    }
    protectedSettings: {
      password: domainJoinerPassword
    }
  }
  dependsOn: [
    compute
  ]
}]

resource vmPrefix_vmStartNumber_3_0_dscextension 'Microsoft.Compute/virtualMachines/extensions@2022-08-01' = [for i in range(0, vmCount): {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/dscextension'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: artifacts_location
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostpoolName
        registrationInfoToken: hostpoolToken
        aadJoin: false
        sessionHostConfigurationLastUpdateTime: contains(systemData, 'hostpoolUpdate') ? systemData.sessionHostConfigurationVersion : ''
      }
    }
  }
  dependsOn: [
    aadjoin
  ]
}]
