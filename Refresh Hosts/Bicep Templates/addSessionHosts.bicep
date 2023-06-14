@description('The name of the resource group to deploy the resources to.')
param location string = resourceGroup().location

@description('Tags for cost allocation')
param customTags1 object

@description('Number of hosts that will be created and added to the hostpool.')
param vmCount int

@maxLength(11)
@description('This prefix will be used in combination with the VM number to create the VM name. This value should only includes alphanumeric characters, so if using “vm” as the prefix, VMs would be named “vm-000”, “vm-001”, etc. You should use a unique prefix to prevent name conflicts/ovewrites in Active Directory.')
param vmPrefix string

@description('This number will be added the VM count to create the VM name. If you want to start your vms with number 10 you would set it to 10, so if using “vm” as the prefix, VMs names would begin at “vm-011”, “vm-012”, etc... You should use vmStartNumber when you have an existing set of vms in a hostpool and want to add new vms to that pool.')
param vmStartNumber int

@description('The size of the session host VMs.')
param vmSKU string

@allowed([
  'Nvidia'
  'AMD'
  'None'
])
@description('The GPU type to use for the hosts. This will determine which GPU drivers will be installed in the hosts if any')
param gpuType string = 'None'

@description('The username for the local admininistrator account.')
param localAdminUsername string

@description('The password for the local admininistrator account.')
@secure()
param localAdminPassword string

@description('Set to true if you want to use a shared image gallery, false if you want to use a marketplace image.')
param useACG bool

@description('The resource group of the Azure Commpute Gallery storing your images.')
param ACG_rg string

@description('Name of the Azure Commpute Gallery storing your images.')
param ACG_Name string

@description('Name of the Azure Compute Gallery Image Definition used to provision your hosts.')
param ACG_ImageDefinition_Name string

@description('The disk type to use for the hosts.')
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
@description('The name of avaiability the hosts will be part of.')
param availabilitySetName string

@description('Set to true if you want to Azure AD Join, false if Active Directory or ADDS join')
param aadJoin bool

@description('IMPORTANT: Please don\'t use this parameter as intune enrollment is not supported yet. True if intune enrollment is selected.  False otherwise')
param intune bool = false

@description('Active Directory Domain to join in FQDN format, ie: something.com. Not required nor used if aadJoin is true.')
param domain string

@description('OU Path in standard LDAP format, ie: OU=name,DC=something,DC=com, not required nor used if aadJoin is true.')
param OUPath string

@description('Domain account that will be used for the domain join process, not required nor used if aadJoin is true.')
param domainJoinerUPN string

@description('Password for the domain account that will be used for the domain join process, not required nor used if aadJoin is true.')
@secure()
param domainJoinerPassword string

@description('The base URI where artifacts required by this template are located.')
param artifacts_location string

@description('The name of the hostpool.')
param hostpoolName string

@description('The token for adding VMs to the hostpool.')
@secure()
param hostpoolToken string

@description('The name of the subnet within the virtual network you want to attach your hosts to.')
param subnetName string

@description('The Reesource ID of the virtual network.')
param vNetId string

@description('The status of the auto-shutdown schedule.')
param autoShutdownStatus string

@description('The shutdown time.')
param autoShutdownTime string

@description('The Time Zone to use for autoShutdownTime.')
param autoShutdownTimeZone string


// ==================== //
// Variable declaration //
// ==================== //

var subnetId = '${vNetId}/subnets/${subnetName}'
var ACG_ImageDefinition_Reference = {
  id: resourceId(ACG_rg, 'Microsoft.Compute/galleries/images', ACG_Name, ACG_ImageDefinition_Name)
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

// =========== //
// Deployments //
// =========== //

resource compute 'Microsoft.Compute/virtualMachines@2021-03-01' = [for i in range(0, vmCount): {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}'
  location: location
  tags: customTags1
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSKU
    }
    availabilitySet: ((availabilityOption == 'AvailabilitySet') ? vmAvailabilitySetResourceId : json('null'))
    osProfile: {
      computerName: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}'
      adminUsername: localAdminUsername
      adminPassword: localAdminPassword
    }
    storageProfile: {
      imageReference: (useACG ? ACG_ImageDefinition_Reference : win10ImageRef)
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
  //zones: [
  //  ((availabilityOption == 'AvailabilityZone') ? string((((i + 0) % 3) + 1)) : json('null'))
  //]

  zones: availabilityOption == 'AvailabilityZone' ? array((((i + 0) % 3) + 1)) : null

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

resource autoshutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = [for i in range(0, vmCount): {
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

resource aadjoinext 'Microsoft.Compute/virtualMachines/extensions@2021-07-01' = [for i in range(0, vmCount): if (aadJoin) {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/aadjoin'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: (intune ? {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    } : null)
  }
  dependsOn: [
    compute
  ]
}]

resource joindomainext 'Microsoft.Compute/virtualMachines/extensions@2022-08-01' = [for i in range(0, vmCount): if (!aadJoin) {
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

resource nvidiagpudriver 'Microsoft.Compute/virtualMachines/extensions@2020-06-01' = [for i in range(0, vmCount): if (gpuType == 'Nvidia') {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/nvidiagpudriver'
  tags: {
    displayName: 'nvidia GPU Extension'
  }
  location: location
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'NvidiaGpuDriverWindows'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    protectedSettings: {}
  }
  dependsOn: [
    compute
  ]
}]

resource amdgpudriver 'Microsoft.Compute/virtualMachines/extensions@2020-06-01' = [for i in range(0, vmCount): if (gpuType == 'AMD') {
  name: '${vmPrefix}-${padLeft((i + vmStartNumber), 3, '0')}/amdgpudriver'
  tags: {
    displayName: 'AMD GPU Extension'
  }
  location: location
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'AmdGpuDriverWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    protectedSettings: {}
  }
  dependsOn: [
    compute
  ]
}]

resource hostpooladd 'Microsoft.Compute/virtualMachines/extensions@2022-08-01' = [for i in range(0, vmCount): {
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
      }
    }
  }
  dependsOn: [
    aadjoinext
  ]
}]
