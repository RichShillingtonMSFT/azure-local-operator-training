﻿# Set paths
$Env:LocalBoxDir = "C:\LocalBox"
$Env:LocalBoxLogsDir = "C:\LocalBox\Logs"

Start-Transcript -Path $Env:LocalBoxLogsDir\New-LocalBoxCluster.log
$starttime = Get-Date

# Import Configuration data file
$LocalBoxConfig = Import-PowerShellDataFile -Path $Env:LocalBoxConfigFile

#region functions
function ConvertFrom-SecureStringToPlainText {
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )

    $Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
    }
}

function BITSRequest {
    param (
        [Parameter(Mandatory=$True)]
        [hashtable]$Params
    )
    $url = $Params['Uri']
    $filename = $Params['Filename']
    $download = Start-BitsTransfer -Source $url -Destination $filename -Asynchronous
    $ProgressPreference = "Continue"
    while ($download.JobState -ne "Transferred") {
        if ($download.JobState -eq "TransientError"){
            Get-BitsTransfer $download.name | Resume-BitsTransfer -Asynchronous
        }
        [int] $dlProgress = ($download.BytesTransferred / $download.BytesTotal) * 100;
        Write-Progress -Activity "Downloading File $filename..." -Status "$dlProgress% Complete:" -PercentComplete $dlProgress;
    }
    Complete-BitsTransfer $download.JobId
    Write-Progress -Activity "Downloading File $filename..." -Status "Ready" -Completed
    $ProgressPreference = "SilentlyContinue"
}

function New-InternalSwitch {
    param (
        $LocalBoxConfig
    )
    $pswitchname = $LocalBoxConfig.InternalSwitch
    $querySwitch = Get-VMSwitch -Name $pswitchname -ErrorAction Ignore
    if (!$querySwitch) {
        New-VMSwitch -SwitchType Internal -MinimumBandwidthMode None -Name $pswitchname | Out-Null

        #Assign IP to Internal Switch
        $InternalAdapter = Get-Netadapter -Name "vEthernet ($pswitchname)"
        $IP = $LocalBoxConfig.PhysicalHostInternalIP
        $Prefix = ($($LocalBoxConfig.MgmtHostConfig.IP).Split("/"))[1]
        $Gateway = $LocalBoxConfig.SDNLABRoute
        $DNS = $LocalBoxConfig.SDNLABDNS

        $params = @{
            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
        }

        $InternalAdapter | New-NetIPAddress @params | Out-Null
        $InternalAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null
    }
    else {
        Write-Host "Internal Switch $pswitchname already exists. Not creating a new internal switch."
    }
}

function Get-FormattedWACMAC {
    Param(
        $LocalBoxConfig
    )
    return $LocalBoxConfig.WACMAC -replace '..(?!$)', '$&-'
}

function GenerateAnswerFile {
    Param(
        [Parameter(Mandatory=$True)] $Hostname,
        [Parameter(Mandatory=$False)] $IsMgmtVM = $false,
        [Parameter(Mandatory=$False)] $IsRouterVM = $false,
        [Parameter(Mandatory=$False)] $IsDCVM = $false,
        [Parameter(Mandatory=$False)] $IsWACVM = $false,
        [Parameter(Mandatory=$False)] $IPAddress = "",
        [Parameter(Mandatory=$False)] $VMMac = "",
        [Parameter(Mandatory=$True)] $LocalBoxConfig
    )

    $formattedMAC = Get-FormattedWACMAC -LocalBoxConfig $LocalBoxConfig
    $encodedPassword = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($($LocalBoxConfig.SDNAdminPassword) + "AdministratorPassword"))
    $wacAnswerXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
<settings pass="specialize">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ProductKey>$($LocalBoxConfig.GUIProductKey)</ProductKey>
<ComputerName>$Hostname</ComputerName>
<RegisteredOwner>$ENV:adminUsername</RegisteredOwner>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
<Metric>20</Metric>
<RouterDiscoveryEnabled>true</RouterDiscoveryEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
</UnicastIpAddresses>
<Identifier>$formattedMAC</Identifier>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$($LocalBoxConfig.SDNLABRoute)</NextHopAddress>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$($LocalBoxConfig.SDNLABDNS)</IpAddress>
</DNSServerSearchOrder>
<Identifier>$formattedMAC</Identifier>
<DNSDomain>$($LocalBoxConfig.SDNDomainFQDN)</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Identification>
<Credentials>
<Domain>$($LocalBoxConfig.SDNDomainFQDN)</Domain>
<Password>$($LocalBoxConfig.SDNAdminPassword)</Password>
<Username>Administrator</Username>
</Credentials>
<JoinDomain>$($LocalBoxConfig.SDNDomainFQDN)</JoinDomain>
</Identification>
</component>
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserAccounts>
<AdministratorPassword>
<PlainText>false</PlainText>
<Value>$encodedPassword</Value>
</AdministratorPassword>
</UserAccounts>
<TimeZone>UTC</TimeZone>
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
<NetworkLocation>Work</NetworkLocation>
<ProtectYourPC>1</ProtectYourPC>
<HideLocalAccountScreen>true</HideLocalAccountScreen>
</OOBE>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-US</UserLocale>
<SystemLocale>en-US</SystemLocale>
<InputLocale>0409:00000409</InputLocale>
<UILanguage>en-US</UILanguage>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

    $components = @"
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Identifier>$VMMac</Identifier>
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
</UnicastIpAddresses>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$($LocalBoxConfig.SDNLABRoute)</NextHopAddress>
<Prefix>0.0.0.0/0</Prefix>
<Metric>100</Metric>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DNSSuffixSearchOrder>
<DomainName wcm:action="add" wcm:keyValue="1">$($LocalBoxConfig.SDNDomainFQDN)</DomainName>
</DNSSuffixSearchOrder>
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$($LocalBoxConfig.SDNLABDNS)</IpAddress>
</DNSServerSearchOrder>
<Identifier>$VMMac</Identifier>
<DisableDynamicUpdate>false</DisableDynamicUpdate>
<DNSDomain>$($LocalBoxConfig.SDNDomainFQDN)</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
"@

    $azsmgmtProdKey = ""
    if ($IsMgmtVM) {
        $azsmgmtProdKey = "<ProductKey>$($LocalBoxConfig.GUIProductKey)</ProductKey>"
    }
    $vmServicing = ""

    if ($IsRouterVM -or $IsDCVM) {
        $components = ""
        $optionXML = ""
        if ($IsRouterVM) {
            $optionXML = @"
<selection name="RemoteAccessServer" state="true" />
<selection name="RasRoutingProtocols" state="true" />
"@
        }
        if ($IsDCVM) {
            $optionXML = @"
<selection name="ADCertificateServicesRole" state="true" />
<selection name="CertificateServices" state="true" />
"@
        }
        $vmServicing = @"
<servicing>
<package action="configure">
<assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="10.0.14393.0" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="" />
$optionXML</package>
</servicing>
"@
    }

    $UnattendXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
$vmServicing<settings pass="specialize">
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ComputerName>$Hostname</ComputerName>
$azsmgmtProdKey</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-us</UserLocale>
<UILanguage>en-us</UILanguage>
<SystemLocale>en-us</SystemLocale>
<InputLocale>en-us</InputLocale>
</component>
$components</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipMachineOOBE>true</SkipMachineOOBE>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
</OOBE>
<UserAccounts>
<AdministratorPassword>
<PlainText>false</PlainText>
<Value>$encodedPassword</Value>
</AdministratorPassword>
</UserAccounts>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@
    if ($IsWACVM) {
        $UnattendXML = $wacAnswerXML
    }
    return $UnattendXML
}

function Restart-VMs {
    Param (
        $LocalBoxConfig,
        [PSCredential]$Credential
    )
    foreach ($VM in $LocalBoxConfig.NodeHostConfig) {
        Write-Host "Restarting VM: $($VM.Hostname)"
        # Invoke-Command -VMName $VM.Hostname -Credential $Credential -ScriptBlock {
        #     Restart-Computer -Force
        # }
        # Restart via host to avoid "Failed to restart the computer with the following error message: Class not registered"
        Restart-VM -Name $VM.Hostname -Force
    }
    Write-Host "Restarting VM: $($LocalBoxConfig.MgmtHostConfig.Hostname)"

    Restart-VM -Name $LocalBoxConfig.MgmtHostConfig.Hostname -Force
    Start-Sleep -Seconds 30

}

function New-ManagementVM {
    Param (
        $Name,
        $VHDXPath,
        $VMSwitch,
        $LocalBoxConfig
    )
    Write-Host "Creating VM $Name"
    # Create disks
    $VHDX1 = New-VHD -ParentPath $VHDXPath -Path "$($LocalBoxConfig.HostVMPath)\$Name.vhdx" -Differencing
    $VHDX2 = New-VHD -Path "$($LocalBoxConfig.HostVMPath)\$Name-Data.vhdx" -SizeBytes 268435456000 -Dynamic

    # Create VM
    # Create Nested VM
    New-VM -Name $Name -MemoryStartupBytes $LocalBoxConfig.AzSMGMTMemoryinGB -VHDPath $VHDX1.Path -SwitchName $VMSwitch -Generation 2 | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $VHDX2.Path
    Set-VM -Name $Name -ProcessorCount $LocalBoxConfig.AzSMGMTProcCount -AutomaticStartAction Start | Out-Null

    Get-VMNetworkAdapter -VMName $Name | Rename-VMNetworkAdapter -NewName "SDN"
    Get-VMNetworkAdapter -VMName $Name | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
    Add-VMNetworkAdapter -VMName $Name -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
    $vmMac = (((Get-VMNetworkAdapter -Name SDN -VMName $Name).MacAddress) -replace '..(?!$)', '$&-')

    Get-VM $Name | Set-VMProcessor -ExposeVirtualizationExtensions $true
    Get-VM $Name | Set-VMMemory -DynamicMemoryEnabled $false
    Get-VM $Name | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200

    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"
    return $vmMac
}

function New-AzLocalNodeVM {
    param (
        $Name,
        $VHDXPath,
        $VMSwitch,
        $LocalBoxConfig
    )
    Write-Host "Creating VM $Name"
    # Create disks
    $VHDX1 = New-VHD -ParentPath $VHDXPath -Path "$($LocalBoxConfig.HostVMPath)\$Name.vhdx" -Differencing
    $VHDX2 = New-VHD -Path "$($LocalBoxConfig.HostVMPath)\$Name-Data.vhdx" -SizeBytes 268435456000 -Dynamic

    # Create S2D Storage
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk1.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk2.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk3.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk4.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk5.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null
    New-VHD -Path "$HostVMPath\$Name-S2D_Disk6.vhdx" -SizeBytes $LocalBoxConfig.S2D_Disk_Size -Dynamic | Out-Null

    # Create Nested VM
    New-VM -Name $Name -MemoryStartupBytes $LocalBoxConfig.NestedVMMemoryinGB -VHDPath $VHDX1.Path -SwitchName $VMSwitch -Generation 2 | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $VHDX2.Path
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk1.vhdx" -VMName $Name | Out-Null
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk2.vhdx" -VMName $Name | Out-Null
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk3.vhdx" -VMName $Name | Out-Null
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk4.vhdx" -VMName $Name | Out-Null
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk5.vhdx" -VMName $Name | Out-Null
    Add-VMHardDiskDrive -Path "$HostVMPath\$Name-S2D_Disk6.vhdx" -VMName $Name | Out-Null

    Set-VM -Name $Name -ProcessorCount 20 -AutomaticStartAction Start
    Get-VMNetworkAdapter -VMName $Name | Rename-VMNetworkAdapter -NewName "SDN"
    Get-VMNetworkAdapter -VMName $Name | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
    # Add-VMNetworkAdapter -VMName $Name -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
    $vmMac = ((Get-VMNetworkAdapter -Name SDN -VMName $Name).MacAddress) -replace '..(?!$)', '$&-'

    Add-VMNetworkAdapter -VMName $Name -SwitchName $VMSwitch -DeviceNaming On -Name StorageA
    Add-VMNetworkAdapter -VMName $Name -SwitchName $VMSwitch -DeviceNaming On -Name StorageB

    Get-VM $Name | Set-VMProcessor -ExposeVirtualizationExtensions $true
    Get-VM $Name | Set-VMMemory -DynamicMemoryEnabled $false
    Get-VM $Name | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
    # Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName StorageA -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-800
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName StorageB -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-800

    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"
    return $vmMac
}

function Set-MGMTVHDX {
    param (
        $VMMac,
        $LocalBoxConfig
    )
    $DriveLetter = $($LocalBoxConfig.HostVMPath).Split(':')
    $path = (("\\localhost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $($LocalBoxConfig.MgmtHostConfig.Hostname) + ".vhdx")
    Write-Host "Performing offline installation of Hyper-V on $($LocalBoxConfig.MgmtHostConfig.Hostname)"
    Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
    Start-Sleep -Seconds 20

    # Mount VHDX - bunch of kludgey logic in here to deal with different partition layouts on the GUI and Azure Local VHD images
    Write-Host "Mounting VHDX file at $path"
    [string]$MountedDrive = ""
    $partition = Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition -PartitionNumber 3
    if (!$partition.DriveLetter) {
        $MountedDrive = "X"
        $partition | Set-Partition -NewDriveLetter $MountedDrive
    }
    else {
        $MountedDrive = $partition.DriveLetter
    }

    # Inject Answer File
    Write-Host "Injecting answer file to $path"
    $UnattendXML = GenerateAnswerFile -HostName $($LocalBoxConfig.MgmtHostConfig.Hostname) -IsMgmtVM $true -IPAddress $LocalBoxConfig.MgmtHostConfig.IP -VMMac $VMMac -LocalBoxConfig $LocalBoxConfig

    Write-Host "Mounted Disk Volume is: $MountedDrive"
    $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
    if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }

    Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force

    # Creating folder structure on AzSMGMT
    Write-Host "Creating VMs\Base folder structure on $($LocalBoxConfig.MgmtHostConfig.Hostname)"
    New-Item -Path ($MountedDrive + ":\VMs\Base") -ItemType Directory -Force | Out-Null

    # Injecting configs into VMs
    Write-Host "Injecting files into $path"
    Copy-Item -Path "$Env:LocalBoxDir\LocalBox-Config.psd1" -Destination ($MountedDrive + ":\") -Recurse -Force
    Copy-Item -Path $guiVHDXPath -Destination ($MountedDrive + ":\VMs\Base\GUI.vhdx") -Force
    Copy-Item -Path $AzLocalVHDXPath -Destination ($MountedDrive + ":\VMs\Base\AzL-node.vhdx") -Force
    New-Item -Path ($MountedDrive + ":\") -Name "Windows Admin Center" -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$($LocalBoxConfig.Paths["WACDir"])\*.msi" -Destination ($MountedDrive + ":\Windows Admin Center") -Recurse -Force

    # Dismount VHDX
    Write-Host "Dismounting VHDX File at path $path"
    Dismount-VHD $path
}

function Set-AzLocalNodeVHDX {
    param (
        $Hostname,
        $IPAddress,
        $VMMac,
        $LocalBoxConfig
    )
    $DriveLetter = $($LocalBoxConfig.HostVMPath).Split(':')
    $path = (("\\localhost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $Hostname + ".vhdx")
    Write-Host "Performing offline installation of Hyper-V on $Hostname"
    Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
    Start-Sleep -Seconds 5

    # Install necessary tools to converge cluster
    Write-Host "Installing and Configuring Failover Clustering on $Hostname"
    Install-WindowsFeature -Vhd $path -Name Failover-Clustering -IncludeAllSubFeature -IncludeManagementTools | Out-Null
    Start-Sleep -Seconds 15

    Write-Host "Mounting VHDX file at $path"
    $partition = Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition -PartitionNumber 3
    if (!$partition.DriveLetter) {
        $MountedDrive = "Y"
        $partition | Set-Partition -NewDriveLetter $MountedDrive
    }
    else {
        $MountedDrive = $partition.DriveLetter
    }

    Write-Host "Injecting answer file to $path"
    $UnattendXML = GenerateAnswerFile -HostName $Hostname -IPAddress $IPAddress -VMMac $VMMac -LocalBoxConfig $LocalBoxConfig
    Write-Host "Mounted Disk Volume is: $MountedDrive"
    $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
    if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }
    Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force

    New-Item -Path ($MountedDrive + ":\VHD") -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$($LocalBoxConfig.Paths.VHDDir)" -Destination ($MountedDrive + ":\VHD") -Recurse -Force
    # Copy-Item -Path "$($LocalBoxConfig.Paths.VHDDir)\Ubuntu.vhdx" -Destination ($MountedDrive + ":\VHD") -Recurse -Force

    # Dismount VHDX
    Write-Host "Dismounting VHDX File at path $path"
    Dismount-VHD $path
}

function Set-DataDrives {
    param (
        $LocalBoxConfig,
        [PSCredential]$Credential
    )
    $VMs = @()
    $VMs += $LocalBoxConfig.MgmtHostConfig.Hostname
    # foreach ($node in $LocalBoxConfig.NodeHostConfig) {
    #     $VMs += $node.Hostname
    # }
    foreach ($VM in $VMs) {
        Invoke-Command -VMName $VM -Credential $Credential -ScriptBlock {

            # Retrieve disk information for disk number 1
            $disk = Get-Disk -Number 1

            # Ensure the disk is online
            if ($disk.IsOffline) {
                Set-Disk -Number 1 -IsOffline $false | Out-Null
                Set-Disk -Number 1 -IsReadOnly $false | Out-Null
            }

            # Initialize the disk only if it hasn't been initialized yet (i.e. PartitionStyle is RAW)
            if ($disk.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number 1 | Out-Null
            }

            # Check if a partition with drive letter D already exists on disk 1
            $partition = Get-Partition -DiskNumber 1 | Where-Object { $_.DriveLetter -eq 'D' }
            if (-not $partition) {
                # Create a new partition on disk 1 using the maximum size and explicitly assign drive letter D
                New-Partition -DiskNumber 1 -UseMaximumSize -DriveLetter D | Out-Null
            }

            # Retrieve volume info for drive D
            $volume = Get-Volume -DriveLetter D
            # Format the volume only if it is not already formatted (assuming NTFS is desired)
            if (($null -eq $volume.FileSystem) -or ($volume.FileSystem -ne 'NTFS')) {
                Format-Volume -DriveLetter D -FileSystem NTFS -Confirm:$false | Out-Null
            }

        }
    }
}

function Test-VMAvailable {
    param (
        $VMName,
        [PSCredential]$Credential
    )
    Invoke-Command -VMName $VMName -ScriptBlock {
        $ErrorOccurred = $false
        do {
            try {
                $ErrorActionPreference = 'Stop'
                Get-VMHost | Out-Null
            }
            catch {
                $ErrorOccurred = $true
            }
        } while ($ErrorOccurred -eq $true)
    } -Credential $Credential -ErrorAction Ignore
    Write-Host "VM $VMName is now online"
}

function Test-AllVMsAvailable
 {
    param (
        $LocalBoxConfig,
        [PSCredential]$Credential
    )
    Write-Host "Testing whether VMs are available..."
    Test-VMAvailable -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $Credential
    foreach ($VM in $LocalBoxConfig.NodeHostConfig) {
        Test-VMAvailable -VMName $VM.Hostname -Credential $Credential
    }
}

function New-NATSwitch {
    Param (
        $LocalBoxConfig
    )
    Write-Host "Creating NAT Switch on switch $($LocalBoxConfig.InternalSwitch)"
    Add-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -DeviceNaming On
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname | Where-Object { $_.Name -match "Network" } | Connect-VMNetworkAdapter -SwitchName $LocalBoxConfig.natHostVMSwitchName
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname | Where-Object { $_.Name -match "Network" } | Rename-VMNetworkAdapter -NewName "NAT"
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name NAT | Set-VMNetworkAdapter -MacAddressSpoofing On

    Add-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name PROVIDER -DeviceNaming On -SwitchName $LocalBoxConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name PROVIDER | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name PROVIDER | Set-VMNetworkAdapterVlan -Access -VlanId $LocalBoxConfig.providerVLAN | Out-Null

    #Create VLAN 110 NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN110 -DeviceNaming On -SwitchName $LocalBoxConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN110 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN110 | Set-VMNetworkAdapterVlan -Access -VlanId $LocalBoxConfig.vlan110VLAN | Out-Null

    #Create VLAN 200 NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN200 -DeviceNaming On -SwitchName $LocalBoxConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN200 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name VLAN200 | Set-VMNetworkAdapterVlan -Access -VlanId $LocalBoxConfig.vlan200VLAN | Out-Null

    #Create Simulated Internet NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name simInternet -DeviceNaming On -SwitchName $LocalBoxConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name simInternet | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Name simInternet | Set-VMNetworkAdapterVlan -Access -VlanId $LocalBoxConfig.simInternetVLAN | Out-Null
}

function Invoke-CommandWithRetry {
    param (
        [string]$VMName,
        [pscredential]$Credential,
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 5,
        [int]$RetryDelay = 10
    )

    $retryCount = 0
    $success = $false

    do {
        try {
            Write-Host "Attempt $($retryCount + 1) to execute command on $VMName..."
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $ScriptBlock -ErrorAction Stop
            $success = $true
            Write-Host "Command executed successfully on $VMName."
        } catch {
            Write-Warning "Failed to execute command on $VMName. Error: $_"
            $retryCount++
            if ($retryCount -lt $MaxRetries) {
                Write-Host "Retrying in $RetryDelay seconds..."
                Start-Sleep -Seconds $RetryDelay
            } else {
                Write-Error "Maximum retries ($MaxRetries) reached. Unable to execute command on $VMName."
            }
        }
    } while (-not $success -and $retryCount -lt $MaxRetries)
}

function Set-NICs {
    Param (
        $LocalBoxConfig,
        [PSCredential]$Credential
    )

    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $Credential -ScriptBlock {
        Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC
    }

    foreach ($VM in $LocalBoxConfig.NodeHostConfig) {

        Write-Host "Setting NICs on VM $($VM.Hostname)"
        Invoke-CommandWithRetry -VMName $VM.Hostname -Credential $Credential -MaxRetries 12 -RetryDelay 10 -ScriptBlock {

            # Set Name and IP Addresses on Storage Interfaces
            $storageNICs = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayValue -match "Storage" }
            foreach ($storageNIC in $storageNICs) {
                Rename-NetAdapter -Name $storageNIC.Name -NewName  $storageNIC.DisplayValue -PassThru | Select-Object Name,PSComputerName
            }
            $storageNICs = Get-Netadapter | Where-Object { $_.Name -match "Storage" }

            # Rename non-storage adapters
            Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC -PassThru | Select-Object Name,PSComputerName

             # Configue WinRM
            Write-Host "Configuring Windows Remote Management in $env:COMPUTERNAME"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

        }
    }
}

function Set-FabricNetwork {
    param (
        $LocalBoxConfig,
        [PSCredential]$localCred
    )
    Start-Sleep -Seconds 20
    Write-Host "Configuring Fabric network on Management VM"
    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $localCred = $using:localCred
        $domainCred = $using:domainCred
        $LocalBoxConfig = $using:LocalBoxConfig

        $ErrorActionPreference = "Stop"

        # Disable Fabric2 Network Adapter
        # Write-Host "Disabling Fabric2 Adapter"
        # Get-NetAdapter FABRIC2 | Disable-NetAdapter -Confirm:$false | Out-Null

        # Enable WinRM on AzSMGMT
        Write-Host "Enabling PSRemoting on $env:COMPUTERNAME"
        Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
        Enable-PSRemoting | Out-Null

        # Disable ServerManager Auto-Start
        Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask | Out-Null

        # Create Hyper-V Networking for AzSMGMT
        Import-Module Hyper-V

        Write-Host "Creating VM Switch on $env:COMPUTERNAME"
        New-VMSwitch -AllowManagementOS $true -Name $LocalBoxConfig.FabricSwitch -NetAdapterName $LocalBoxConfig.FabricNIC -MinimumBandwidthMode None | Out-Null

        Write-Host "Configuring NAT on $env:COMPUTERNAME"
        $Prefix = ($LocalBoxConfig.natSubnet.Split("/"))[1]
        $natIP = ($LocalBoxConfig.natSubnet.TrimEnd("0./$Prefix")) + (".1")
        $provIP = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24") + "254"
        $vlan200IP = $LocalBoxConfig.BGPRouterIP_VLAN200.TrimEnd("1/24") + "250"
        $vlan110IP = $LocalBoxConfig.BGPRouterIP_VLAN110.TrimEnd("1/24") + "250"
        $provGW = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("/24")
        $provpfx = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
        $vlan200pfx = $LocalBoxConfig.BGPRouterIP_VLAN200.Split("/")[1]
        $vlan110pfx = $LocalBoxConfig.BGPRouterIP_VLAN110.Split("/")[1]
        $simInternetIP = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.TrimEnd("1/24") + "254"
        $simInternetPFX = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]
        New-VMSwitch -SwitchName NAT -SwitchType Internal -MinimumBandwidthMode None | Out-Null
        New-NetIPAddress -IPAddress $natIP -PrefixLength $Prefix -InterfaceAlias "vEthernet (NAT)" | Out-Null
        New-NetNat -Name NATNet -InternalIPInterfaceAddressPrefix $LocalBoxConfig.natSubnet | Out-Null

        Write-Host "Configuring Provider NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
        Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
        New-NetIPAddress -InterfaceAlias "PROVIDER" -IPAddress $provIP -PrefixLength $provpfx | Out-Null

        Write-Host "Configuring VLAN200 NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
        Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
        New-NetIPAddress -InterfaceAlias "VLAN200" -IPAddress $vlan200IP -PrefixLength $vlan200pfx | Out-Null

        Write-Host "Configuring VLAN110 NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN110" }
        Rename-NetAdapter -name $NIC.name -newname "VLAN110" | Out-Null
        New-NetIPAddress -InterfaceAlias "VLAN110" -IPAddress $vlan110IP -PrefixLength $vlan110pfx | Out-Null

        Write-Host "Configuring simulatedInternet NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "simInternet" }
        Rename-NetAdapter -name $NIC.name -newname "simInternet" | Out-Null
        New-NetIPAddress -InterfaceAlias "simInternet" -IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null

        Write-Host "Configuring NAT"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Network Adapter" -or $_.RegistryValue -eq "NAT" }
        Rename-NetAdapter -name $NIC.name -newname "Internet" | Out-Null
        $internetIP = $LocalBoxConfig.natHostSubnet.Replace("0/24", "5")
        $internetGW = $LocalBoxConfig.natHostSubnet.Replace("0/24", "1")
        Start-Sleep -Seconds 15
        $internetIndex = (Get-NetAdapter | Where-Object { $_.Name -eq "Internet" }).ifIndex
        Start-Sleep -Seconds 15
        New-NetIPAddress -IPAddress $internetIP -PrefixLength 24 -InterfaceIndex $internetIndex -DefaultGateway $internetGW -AddressFamily IPv4 | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $internetIndex -ServerAddresses ($LocalBoxConfig.natDNS) | Out-Null

        # Provision Public and Private VIP Route
        New-NetRoute -DestinationPrefix $LocalBoxConfig.PublicVIPSubnet -NextHop $provGW -InterfaceAlias PROVIDER | Out-Null

        # Remove Gateway from Fabric NIC
        Write-Host "Removing Gateway from Fabric NIC"
        $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -match "vSwitch-Fabric" }).InterfaceIndex
        Remove-NetRoute -InterfaceIndex $index -DestinationPrefix "0.0.0.0/0" -Confirm:$false
    }
}

function New-DCVM {
    Param (
        $LocalBoxConfig,
        [PSCredential]$localCred,
        [PSCredential]$domainCred
    )
    Write-Host "Creating domain controller VM"
    $adminUser = $env:adminUsername
    $Unattend = GenerateAnswerFile -Hostname $LocalBoxConfig.DCName -IsDCVM $true -LocalBoxConfig $LocalBoxConfig
    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $adminUser = $using:adminUser
        $LocalBoxConfig = $using:LocalBoxConfig
        $localCred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $VMName = $LocalBoxConfig.DCName

        # Create Virtual Machine
        Write-Host "Creating $VMName differencing disks"
        New-VHD -ParentPath ($ParentDiskPath + $OSVHDX) -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Differencing | Out-Null

        Write-Host "Creating $VMName virtual machine"
        New-VM -Name $VMName -VHDPath ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Path ($vmpath + $VMName) -Generation 2 | Out-Null

        Write-Host "Setting $VMName Memory"
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $LocalBoxConfig.MEM_DC -MaximumBytes $LocalBoxConfig.MEM_DC -MinimumBytes 500MB | Out-Null

        Write-Host "Configuring $VMName's networking"
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null
        Add-VMNetworkAdapter -VMName $VMName -Name $LocalBoxConfig.DCName -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming 'On' | Out-Null

        Write-Host "Configuring $VMName's settings"
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null

        # Inject Answer File
        Write-Host "Mounting and injecting answer file into the $VMName VM."
        New-Item -Path "C:\TempMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
        Write-Host "Applying Unattend file to Disk Image..."
        New-Item -Path C:\TempMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        Set-Content -Value $using:Unattend -Path "C:\TempMount\Windows\Panther\Unattend.xml"  -Force
        Write-Host "Dismounting Windows Image"
        Dismount-WindowsImage -Path "C:\TempMount" -Save | Out-Null
        Remove-Item "C:\TempMount" | Out-Null

        # Start Virtual Machine
        Write-Host "Starting Virtual Machine $VMName"
        Start-VM -Name $VMName | Out-Null

        # Wait until the VM is restarted
        while ((Invoke-Command -VMName $VMName -Credential $using:localCred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        Write-Host "Configuring $VMName and Installing Active Directory."
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $LocalBoxConfig -ScriptBlock {
            $LocalBoxConfig = $args[0]
            $DCName = $LocalBoxConfig.DCName
            $IP = $LocalBoxConfig.SDNLABDNS
            $PrefixLength = ($($LocalBoxConfig.MgmtHostConfig.IP).Split("/"))[1]
            $SDNLabRoute = $LocalBoxConfig.SDNLABRoute
            $DomainFQDN = $LocalBoxConfig.SDNDomainFQDN
            $DomainNetBiosName = $DomainFQDN.Split(".")[0]

            Write-Host "Configuring NIC Settings for $DCName"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq $DCName }
            Rename-NetAdapter -name $NIC.name -newname $DCName | Out-Null
            New-NetIPAddress -InterfaceAlias $DCName -IPAddress $ip -PrefixLength $PrefixLength -DefaultGateway $SDNLabRoute | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias $DCName -ServerAddresses $IP | Out-Null
            Install-WindowsFeature -name AD-Domain-Services -IncludeManagementTools | Out-Null

            Write-Host "Configuring Trusted Hosts on $DCName"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

            Write-Host "Installing Active Directory forest on $DCName."
            $SecureString = ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force
            Install-ADDSForest -DomainName $DomainFQDN -DomainMode 'WinThreshold' -DatabasePath "C:\Domain" -DomainNetBiosName $DomainNetBiosName -SafeModeAdministratorPassword $SecureString -InstallDns -Confirm -Force -NoRebootOnCompletion # | Out-Null
        }

        Write-Host "Stopping $VMName"
        Get-VM $VMName | Stop-VM
        Write-Host "Starting $VMName"
        Get-VM $VMName | Start-VM

        # Wait until DC is created and rebooted
        while ((Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $LocalBoxConfig.DCName { (Get-ADDomainController $args[0]).enabled } -ea SilentlyContinue) -ne $true) { Start-Sleep -Seconds 5 }

        Write-Host "Configuring User Accounts and Groups in Active Directory"
        Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $LocalBoxConfig, $adminUser -ScriptBlock {
            $LocalBoxConfig = $args[0]
            $adminUser = $args[1]
            $SDNDomainFQDN = $LocalBoxConfig.SDNDomainFQDN
            $SecureString = ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force
            Set-ADDefaultDomainPasswordPolicy -ComplexityEnabled $false -Identity $LocalBoxConfig.SDNDomainFQDN -MinPasswordLength 0

            $params = @{
                Name                  = 'NC Admin'
                GivenName             = 'NC'
                Surname               = 'Admin'
                SamAccountName        = 'NCAdmin'
                UserPrincipalName     = "NCAdmin@$SDNDomainFQDN"
                AccountPassword       = $SecureString
                Enabled               = $true
                ChangePasswordAtLogon = $false
                CannotChangePassword  = $true
                PasswordNeverExpires  = $true
            }
            New-ADUser @params

            $params = @{
                Name                  = $adminUser
                GivenName             = 'Jumpstart'
                Surname               = 'Jumpstart'
                SamAccountName        = $adminUser
                UserPrincipalName     = "$adminUser@$SDNDomainFQDN"
                AccountPassword       = $SecureString
                Enabled               = $true
                ChangePasswordAtLogon = $false
                CannotChangePassword  = $true
                PasswordNeverExpires  = $true
            }
            New-ADUser @params

            $params.Name = 'NC Client'
            $params.Surname = 'Client'
            $params.SamAccountName = 'NCClient'
            $params.UserPrincipalName = "NCClient@$SDNDomainFQDN"
            New-ADUser @params

            New-ADGroup -name “NCAdmins” -groupscope Global
            New-ADGroup -name “NCClients” -groupscope Global

            Add-ADGroupMember "Domain Admins" "NCAdmin"
            Add-ADGroupMember "NCAdmins" "NCAdmin"
            Add-ADGroupMember "NCClients" "NCClient"
            Add-ADGroupMember "NCClients" $adminUser
            Add-ADGroupMember "NCAdmins" $adminUser
            Add-ADGroupMember "Domain Admins" $adminUser
            Add-ADGroupMember "NCAdmins" $adminUser
            Add-ADGroupMember "NCClients" $adminUser

            # Set Administrator Account Not to Expire
            Get-ADUser Administrator | Set-ADUser -PasswordNeverExpires $true  -CannotChangePassword $true
            Get-ADUser $adminUser | Set-ADUser -PasswordNeverExpires $true  -CannotChangePassword $true

            # Set DNS Forwarder
            Write-Host "Adding DNS Forwarders"
            Add-DnsServerForwarder $LocalBoxConfig.natDNS

            # Create Enterprise CA
            Write-Host "Installing and Configuring Active Directory Certificate Services and Certificate Templates"
            Install-WindowsFeature -Name AD-Certificate -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Install-AdcsCertificationAuthority -CAtype 'EnterpriseRootCa' -CryptoProviderName 'ECDSA_P256#Microsoft Software Key Storage Provider' -KeyLength 256 -HashAlgorithmName 'SHA256' -ValidityPeriod 'Years' -ValidityPeriodUnits 10 -Confirm:$false | Out-Null

            # Give WebServer Template Enroll rights for Domain Computers
            $filter = "(CN=WebServer)"
            $ConfigContext = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $ConfigContext = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigContext"
            $ds = New-object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ConfigContext", $filter)
            $Template = $ds.Findone().GetDirectoryEntry()

            if ($null -ne $Template) {
                $objUser = New-Object System.Security.Principal.NTAccount("Domain Computers")
                $objectGuid = New-Object Guid 0e10c968-78fb-11d2-90d4-00c04f79dc55
                $ADRight = [System.DirectoryServices.ActiveDirectoryRights]"ExtendedRight"
                $ACEType = [System.Security.AccessControl.AccessControlType]"Allow"
                $ACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList $objUser, $ADRight, $ACEType, $objectGuid
                $Template.ObjectSecurity.AddAccessRule($ACE)
                $Template.commitchanges()
            }

            CMD.exe /c "certutil -setreg ca\ValidityPeriodUnits 8" | Out-Null
            Restart-Service CertSvc
            Start-Sleep -Seconds 60

            #Issue Certificate Template
            CMD.exe /c "certutil -SetCATemplates +WebServer"
        }
    }
}

function Set-DHCPServerOnDC {
    Param (
        $LocalBoxConfig,
        [PSCredential]$domainCred,
        [PSCredential]$localCred
    )
    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        # Add NIC for VLAN200 for DHCP server (for use with Arc-enabled VMs)
        Add-VMNetworkAdapter -VMName $VMName -Name "VLAN200" -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming "On"
        Get-VMNetworkAdapter -VMName $VMName -Name "VLAN200" | Set-VMNetworkAdapterVLAN -Access -VlanId $LocalBoxConfig.AKSVLAN
    }
    Write-Host "Configuring DHCP scope on DHCP server."
    # Set up DHCP scope for Arc resource bridge
    Invoke-Command -VMName $LocalBoxConfig.DCName -Credential $using:domainCred -ArgumentList $LocalBoxConfig -ScriptBlock {
        $LocalBoxConfig = $args[0]

        Write-Host "Configuring NIC settings for $DCName VLAN200"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
        Rename-NetAdapter -name $NIC.name -newname VLAN200 | Out-Null
        New-NetIPAddress -InterfaceAlias VLAN200 -IPAddress $LocalBoxConfig.dcVLAN200IP -PrefixLength ($LocalBoxConfig.AKSIPPrefix.split("/"))[1] -DefaultGateway $LocalBoxConfig.AKSGWIP | Out-Null

        # Install DHCP feature
        Install-WindowsFeature DHCP -IncludeManagementTools
        CMD.exe /c "netsh dhcp add securitygroups"
        Restart-Service dhcpserver

        # Allow DHCP in domain
        $dnsName = $LocalBoxConfig.DCName
        $fqdnsName = $LocalBoxConfig.DCName + "." + $LocalBoxConfig.SDNDomainFQDN
        Add-DhcpServerInDC -DnsName $fqdnsName -IPAddress $LocalBoxConfig.dcVLAN200IP
        Get-DHCPServerInDC

        # Bind DHCP only to VLAN200 NIC
        Set-DhcpServerv4Binding -ComputerName $dnsName -InterfaceAlias $dnsName -BindingState $false
        Set-DhcpServerv4Binding -ComputerName $dnsName -InterfaceAlias VLAN200 -BindingState $true

        # Add DHCP scope for Resource bridge VMs
        Add-DhcpServerv4Scope -name "ResourceBridge" -StartRange $LocalBoxConfig.rbVipStart -EndRange $LocalBoxConfig.rbVipEnd -SubnetMask 255.255.255.0 -State Active
        $scope = Get-DhcpServerv4Scope
        Add-DhcpServerv4ExclusionRange -ScopeID $scope.ScopeID.IPAddressToString -StartRange $LocalBoxConfig.rbDHCPExclusionStart -EndRange $LocalBoxConfig.rbDHCPExclusionEnd
        Set-DhcpServerv4OptionValue -ComputerName $dnsName -ScopeId $scope.ScopeID.IPAddressToString -DnsServer $LocalBoxConfig.SDNLABDNS -Router $LocalBoxConfig.BGPRouterIP_VLAN200.Trim("/24")
    }
}

function New-RouterVM {
    Param (
        $LocalBoxConfig,
        [PSCredential]$localCred
    )
    $Unattend = GenerateAnswerFile -Hostname $LocalBoxConfig.BGPRouterName -IsRouterVM $true -LocalBoxConfig $LocalBoxConfig
    Invoke-Command -VMName $LocalBoxConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $LocalBoxConfig = $using:LocalBoxConfig
        $localCred = $using:localcred
        $ParentDiskPath = "C:\VMs\Base\AzL-node.vhdx"
        $vmpath = "D:\VMs\"
        $VMName = $LocalBoxConfig.BGPRouterName

        # Create Host OS Disk
        Write-Host "Creating $VMName differencing disks"
        New-VHD -ParentPath $ParentDiskPath -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Differencing | Out-Null

        # Create VM
        Write-Host "Creating the $VMName VM."
        New-VM -Name $VMName -VHDPath ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Path ($vmpath + $VMName) -Generation 2 | Out-Null

        # Set VM Configuration
        Write-Host "Setting $VMName's VM Configuration"
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $LocalBoxConfig.MEM_BGP -MinimumBytes 500MB -MaximumBytes $LocalBoxConfig.MEM_BGP | Out-Null
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStopAction ShutDown | Out-Null

        # Configure VM Networking
        Write-Host "Configuring $VMName's Networking"
        Add-VMNetworkAdapter -VMName $VMName -Name Mgmt -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name Provider -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN110 -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN200 -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name SIMInternet -SwitchName $LocalBoxConfig.FabricSwitch -DeviceNaming On
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName Provider -Access -VlanId $LocalBoxConfig.providerVLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN110 -Access -VlanId $LocalBoxConfig.vlan110VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN200 -Access -VlanId $LocalBoxConfig.vlan200VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName SIMInternet -Access -VlanId $LocalBoxConfig.simInternetVLAN
        Add-VMNetworkAdapter -VMName $VMName -Name NAT -SwitchName NAT -DeviceNaming On

        # Mount disk and inject Answer File
        Write-Host "Mounting Disk Image and Injecting Answer File into the $VMName VM."
        New-Item -Path "C:\TempBGPMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempBGPMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
        New-Item -Path C:\TempBGPMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        Set-Content -Value $using:Unattend -Path "C:\TempBGPMount\Windows\Panther\Unattend.xml" -Force

        # Enable remote access
        Write-Host "Enabling Remote Access"
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RasRoutingProtocols -All -LimitAccess | Out-Null
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RemoteAccessPowerShell -All -LimitAccess | Out-Null
        Write-Host "Dismounting Disk Image for $VMName VM."
        Dismount-WindowsImage -Path "C:\TempBGPMount" -Save | Out-Null
        Remove-Item "C:\TempBGPMount"

        # Start the VM
        Write-Host "Starting $VMName VM."
        Start-VM -Name $VMName

        # Wait for VM to be started
        while ((Invoke-Command -VMName $VMName -Credential $localcred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        Write-Host "Configuring $VMName"
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $LocalBoxConfig -ScriptBlock {
            $LocalBoxConfig = $args[0]
            $DNS = $LocalBoxConfig.SDNLABDNS
            $natSubnet = $LocalBoxConfig.natSubnet
            $natDNS = $LocalBoxConfig.natSubnet
            $MGMTIP = $LocalBoxConfig.BGPRouterIP_MGMT.Split("/")[0]
            $MGMTPFX = $LocalBoxConfig.BGPRouterIP_MGMT.Split("/")[1]
            $PNVIP = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.Split("/")[0]
            $PNVPFX = $LocalBoxConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
            $VLANIP = $LocalBoxConfig.BGPRouterIP_VLAN200.Split("/")[0]
            $VLANPFX = $LocalBoxConfig.BGPRouterIP_VLAN200.Split("/")[1]
            $VLAN110IP = $LocalBoxConfig.BGPRouterIP_VLAN110.Split("/")[0]
            $VLAN110PFX = $LocalBoxConfig.BGPRouterIP_VLAN110.Split("/")[1]
            $simInternetIP = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.Split("/")[0]
            $simInternetPFX = $LocalBoxConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]

            # Renaming NetAdapters and setting up the IPs inside the VM using CDN parameters
            Write-Host "Configuring $env:COMPUTERNAME's Networking"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Mgmt" }
            Rename-NetAdapter -name $NIC.name -newname "Mgmt" | Out-Null
            New-NetIPAddress -InterfaceAlias "Mgmt" -IPAddress $MGMTIP -PrefixLength $MGMTPFX | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias “Mgmt” -ServerAddresses $DNS | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
            Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
            New-NetIPAddress -InterfaceAlias "PROVIDER" -IPAddress $PNVIP -PrefixLength $PNVPFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN200" -IPAddress $VLANIP -PrefixLength $VLANPFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN110" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN110" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN110" -IPAddress $VLAN110IP -PrefixLength $VLAN110PFX | Out-Null

            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "SIMInternet" }
            Rename-NetAdapter -name $NIC.name -newname "SIMInternet" | Out-Null
            New-NetIPAddress -InterfaceAlias "SIMInternet" -IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null

            # Configure NAT
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "NAT" }
            Rename-NetAdapter -name $NIC.name -newname "NAT" | Out-Null
            $Prefix = ($natSubnet.Split("/"))[1]
            $natIP = ($natSubnet.TrimEnd("0./$Prefix")) + (".10")
            $natGW = ($natSubnet.TrimEnd("0./$Prefix")) + (".1")
            New-NetIPAddress -InterfaceAlias "NAT" -IPAddress $natIP -PrefixLength $Prefix -DefaultGateway $natGW | Out-Null
            if ($natDNS) {
                Set-DnsClientServerAddress -InterfaceAlias "NAT" -ServerAddresses $natDNS | Out-Null
            }

            # Configure Trusted Hosts
            Write-Host "Configuring Trusted Hosts on $env:COMPUTERNAME"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

            # Installing Remote Access
            Write-Host "Installing Remote Access on $env:COMPUTERNAME"
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null

            # Adding a BGP Router to the VM
            # Write-Host "Creating BGP Router on $env:COMPUTERNAME"
            # Add-BgpRouter -BGPIdentifier $PNVIP -LocalASN $LocalBoxConfig.BGPRouterASN -TransitRouting 'Enabled' -ClusterId 1 -RouteReflector 'Enabled'

            # Configure BGP Peers - commented during refactor for 23h2
            # if ($LocalBoxConfig.ConfigureBGPpeering -and $LocalBoxConfig.ProvisionNC) {
            #     Write-Verbose "Peering future MUX/GWs"
            #     $Mux01IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "4"
            #     $GW01IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
            #     $GW02IP = ($LocalBoxConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"
            #     $params = @{
            #         Name           = 'MUX01'
            #         LocalIPAddress = $PNVIP
            #         PeerIPAddress  = $Mux01IP
            #         PeerASN        = $LocalBoxConfig.SDNASN
            #         OperationMode  = 'Mixed'
            #         PeeringMode    = 'Automatic'
            #     }
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW01'
            #     $params.PeerIPAddress = $GW01IP
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW02'
            #     $params.PeerIPAddress = $GW02IP
            #     Add-BgpPeer @params -PassThru
            # }

       }
    }
}

function Test-InternetConnect {
    $testIP = $LocalBoxConfig.natDNS
    $ErrorActionPreference = "Stop"
    $intConnect = Test-NetConnection -ComputerName $testip -Port 53

    if (!$intConnect.TcpTestSucceeded) {
        throw "Unable to connect to DNS by pinging $($LocalBoxConfig.natDNS) - Network access to this IP is required."
    }
}

function Set-HostNAT {
    param (
        $LocalBoxConfig
    )

    $switchExist = Get-NetAdapter | Where-Object { $_.Name -match $LocalBoxConfig.natHostVMSwitchName }
    if (!$switchExist) {
        Write-Host "Creating NAT Switch: $($LocalBoxConfig.natHostVMSwitchName)"
        # Create Internal VM Switch for NAT
        New-VMSwitch -Name $LocalBoxConfig.natHostVMSwitchName -SwitchType Internal | Out-Null

        Write-Host "Applying IP Address to NAT Switch: $($LocalBoxConfig.natHostVMSwitchName)"
        # Apply IP Address to new Internal VM Switch
        $intIdx = (Get-NetAdapter | Where-Object { $_.Name -match $LocalBoxConfig.natHostVMSwitchName }).ifIndex
        $natIP = $LocalBoxConfig.natHostSubnet.Replace("0/24", "1")
        New-NetIPAddress -IPAddress $natIP -PrefixLength 24 -InterfaceIndex $intIdx | Out-Null

        # Create NetNAT
        Write-Host "Creating new Net NAT"
        New-NetNat -Name $LocalBoxConfig.natHostVMSwitchName  -InternalIPInterfaceAddressPrefix $LocalBoxConfig.natHostSubnet | Out-Null
    }
}

#endregion

#region Main
$guiVHDXPath = $LocalBoxConfig.guiVHDXPath
$AzLocalVHDXPath = $LocalBoxConfig.AzLocalVHDXPath
$HostVMPath = $LocalBoxConfig.HostVMPath
$InternalSwitch = $LocalBoxConfig.InternalSwitch
$natDNS = $LocalBoxConfig.natDNS
$natSubnet = $LocalBoxConfig.natSubnet
$tenantId = $env:spnTenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup

Import-Module Hyper-V

$DeploymentProgressString = 'Downloading nested VMs VHDX files'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

# Create paths
foreach ($path in $LocalBoxConfig.Paths.GetEnumerator()) {
    Write-Host "Creating $($path.Key) path at $($path.Value)"
    New-Item -Path $path.Value -ItemType Directory -Force | Out-Null
}

# Download LocalBox VHDs
Write-Host "[Build cluster - Step 1/11] Downloading LocalBox VHDs" -ForegroundColor Green

$Env:AZCOPY_BUFFER_GB = 4
Write-Output "Downloading nested VMs VHDX files. This can take some time, hold tight..."

azcopy cp 'https://azlimagestoresa.blob.core.windows.net/vhds/AzL2504.vhdx' "$($LocalBoxConfig.Paths.VHDDir)\AzL-node.vhdx" --recursive=true --check-length=false --log-level=ERROR
azcopy cp 'https://jumpstartprodsg.blob.core.windows.net/hcibox23h2/WinServerApril2024.vhdx' "$($LocalBoxConfig.Paths.VHDDir)\GUI.vhdx" --recursive=true --check-length=false --log-level=ERROR
azcopy cp 'https://jumpstartprodsg.blob.core.windows.net/hcibox23h2/WinServerApril2024.sha256' "$($LocalBoxConfig.Paths.VHDDir)\GUI.sha256" --recursive=true --check-length=false --log-level=ERROR

$checksum = Get-FileHash -Path "$($LocalBoxConfig.Paths.VHDDir)\GUI.vhdx"
$hash = Get-Content -Path "$($LocalBoxConfig.Paths.VHDDir)\GUI.sha256"
if ($checksum.Hash -eq $hash) {
    Write-Host "GUI.vhdx has valid checksum. Continuing..."
}
else {
    Write-Error "GUI.vhdx is corrupt. Aborting deployment. Re-run C:\LocalBox\LocalBoxLogonScript.ps1 to retry"
    throw
}

azcopy cp 'https://azlimagestoresa.blob.core.windows.net/labfiles/LabFiles.zip' "$($LocalBoxConfig.Paths.TempDir)\LabFiles.zip" --recursive=true --check-length=false --log-level=ERROR
New-Item -Path 'C:\LabFiles' -ItemType Directory -Force
Expand-Archive -Path "$($LocalBoxConfig.Paths.TempDir)\LabFiles.zip" -DestinationPath 'C:\LabFiles' -Force
Remove-Item "$($LocalBoxConfig.Paths.TempDir)\LabFiles.zip" -Force

# Set credentials
$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist "Administrator", (ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force)

$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($LocalBoxConfig.SDNDomainFQDN.Split(".")[0]) +"\Administrator"), (ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force)

# Enable PSRemoting
Write-Host "[Build cluster - Step 2/11] Preparing Azure VM virtualization host..." -ForegroundColor Green
Write-Host "Enabling PS Remoting on client..."
Enable-PSRemoting
set-item WSMan:localhost\client\trustedhosts -value * -Force
Enable-WSManCredSSP -Role Client -DelegateComputer "*.$($LocalBoxConfig.SDNDomainFQDN)" -Force

###############################################################################
# Configure Hyper-V host
###############################################################################
Write-Host "Checking internet connectivity"
Test-InternetConnect

Write-Host "Creating Internal Switch"
New-InternalSwitch -LocalBoxConfig $LocalBoxConfig

Write-Host "Creating NAT Switch"
Set-HostNAT -LocalBoxConfig $LocalBoxConfig

Write-Host "Configuring LocalBox-Client Hyper-V host"
Set-VMHost -VirtualHardDiskPath $HostVMPath -VirtualMachinePath $HostVMPath -EnableEnhancedSessionMode $true

Write-Host "Copying VHDX Files to Host virtualization drive"
$guipath = "$HostVMPath\GUI.vhdx"
$azlocalpath = "$HostVMPath\AzL-node.vhdx"
Copy-Item -Path $LocalBoxConfig.guiVHDXPath -Destination $guipath -Force | Out-Null
Copy-Item -Path $LocalBoxConfig.AzLocalVHDXPath -Destination $azlocalpath -Force | Out-Null

################################################################################
# Create the three nested Virtual Machines
################################################################################

$DeploymentProgressString = 'Creating and configuring nested VMs'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

# First create the Management VM (AzSMGMT)
Write-Host "[Build cluster - Step 3/11] Creating Management VM (AzSMGMT)..." -ForegroundColor Green
$mgmtMac = New-ManagementVM -Name $($LocalBoxConfig.MgmtHostConfig.Hostname) -VHDXPath "$HostVMPath\GUI.vhdx" -VMSwitch $InternalSwitch -LocalBoxConfig $LocalBoxConfig
Set-MGMTVHDX -VMMac $mgmtMac -LocalBoxConfig $LocalBoxConfig

# Create the Azure Local node VMs
Write-Host "[Build cluster - Step 4/11] Creating Azure Local node VMs (AzLHOSTx)..." -ForegroundColor Green
foreach ($VM in $LocalBoxConfig.NodeHostConfig) {
    $mac = New-AzLocalNodeVM -Name $VM.Hostname -VHDXPath $azlocalpath -VMSwitch $InternalSwitch -LocalBoxConfig $LocalBoxConfig
    Set-AzLocalNodeVHDX -HostName $VM.Hostname -IPAddress $VM.IP -VMMac $mac  -LocalBoxConfig $LocalBoxConfig
}

# Start Virtual Machines
Write-Host "[Build cluster - Step 5/11] Starting VMs..." -ForegroundColor Green
Write-Host "Starting VM: $($LocalBoxConfig.MgmtHostConfig.Hostname)"
Start-VM -Name $LocalBoxConfig.MgmtHostConfig.Hostname
foreach ($VM in $LocalBoxConfig.NodeHostConfig) {
    Set-VMMemory -VMName $VM.Hostname -DynamicMemoryEnabled $false
    Set-VM -VMName $VM.Hostname -CheckpointType Disabled
    Set-VMKeyProtector -VMName $VM.Hostname -NewLocalKeyProtector
    Enable-VmTpm -VMName $VM.Hostname
    Write-Host "Starting VM: $($VM.Hostname)"
    Start-VM -Name $VM.Hostname
}

#######################################################################################
# Prep the virtualization environment
#######################################################################################
Write-Host "[Build cluster - Step 6/11] Configuring host networking and storage..." -ForegroundColor Green
# Wait for AzSHOSTs to come online
Test-AllVMsAvailable -LocalBoxConfig $LocalBoxConfig -Credential $localCred
Start-Sleep -Seconds 60

# Format and partition data drives
Set-DataDrives -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Configure networking
Set-NICs -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Restart Machines
Restart-VMs -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Wait for AzSHOSTs to come online
Test-AllVMsAvailable -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Configure networking
Set-NICs -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Format and partition data drives
Set-DataDrives -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# Create NAT Virtual Switch on AzSMGMT
New-NATSwitch -LocalBoxConfig $LocalBoxConfig

# Configure fabric network on AzSMGMT
Set-FabricNetwork -LocalBoxConfig $LocalBoxConfig -localCred $localCred

#######################################################################################
# Provision the router, domain controller, and WAC VMs and join the hosts to the domain
#######################################################################################

$DeploymentProgressString = 'Provisioning Router VM'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

# Provision Router VM on AzSMGMT
Write-Host "[Build cluster - Step 7/11] Build router VM..." -ForegroundColor Green
New-RouterVM -LocalBoxConfig $LocalBoxConfig -localCred $localCred

$DeploymentProgressString = 'Provisioning Domain controller VM'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

# Provision Domain controller VM on AzSMGMT
Write-Host "[Build cluster - Step 8/11] Building Domain Controller VM..." -ForegroundColor Green
New-DCVM -LocalBoxConfig $LocalBoxConfig -localCred $localCred -domainCred $domainCred

Write-Host "[Build cluster - Step 9/11] Preparing Azure local cluster cloud deployment..." -ForegroundColor Green

$DeploymentProgressString = 'Preparing Azure Local cluster deployment'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

Write-Host "[Build cluster - Step 10/11] Running bootstrap on AzL Hosts..." -ForegroundColor Green

Invoke-Command -VMName $LocalBoxConfig.NodeHostConfig[0].HostName -Credential $LocalCred -ScriptBlock {
    powershell.exe -ExecutionPolicy Unrestricted -Command "C:\startupScriptsWrapper.ps1 'C:\ImageComposition\Scripts\scheduledTaskRunner.ps1'"
    powershell.exe -ExecutionPolicy Unrestricted -Command "C:\startupScriptsWrapper.ps1 'C:\BootstrapPackage\bootstrap\content\Bootstrap-Setup.ps1 -Install'"
}

Invoke-Command -VMName $LocalBoxConfig.NodeHostConfig[1].HostName -Credential $LocalCred -ScriptBlock {
    powershell.exe -ExecutionPolicy Unrestricted -Command "C:\startupScriptsWrapper.ps1 'C:\ImageComposition\Scripts\scheduledTaskRunner.ps1'"
    powershell.exe -ExecutionPolicy Unrestricted -Command "C:\startupScriptsWrapper.ps1 'C:\BootstrapPackage\bootstrap\content\Bootstrap-Setup.ps1 -Install'"
}

Start-Sleep -Seconds 120

Write-Host "[Build cluster - Step 11/11] Configuring Host VM..." -ForegroundColor Green

Install-WindowsFeature -Name RSAT-ADDS -IncludeAllSubFeature -IncludeManagementTools | Out-Null
Install-WindowsFeature -Name GPMC -IncludeAllSubFeature -IncludeManagementTools | Out-Null
Install-WindowsFeature -Name RSAT-Clustering-Mgmt, RSAT-Clustering-PowerShell -IncludeAllSubFeature -IncludeManagementTools | Out-Null
Install-WindowsFeature -Name RSAT-DNS-Server | Out-Null

# Disable Edge 'First Run' Setup
Write-Host "Configuring Microsoft Edge."
$edgePolicyRegistryPath = 'HKLM:SOFTWARE\Policies\Microsoft\Edge'
$firstRunRegistryName = 'HideFirstRunExperience'
$firstRunRegistryValue = '0x00000001'
$savePasswordRegistryName = 'PasswordManagerEnabled'
$savePasswordRegistryValue = '0x00000000'

if (-NOT (Test-Path -Path $edgePolicyRegistryPath)) {
    New-Item -Path $edgePolicyRegistryPath -Force | Out-Null
}

New-ItemProperty -Path $edgePolicyRegistryPath -Name $firstRunRegistryName -Value $firstRunRegistryValue -PropertyType DWORD -Force
New-ItemProperty -Path $edgePolicyRegistryPath -Name $savePasswordRegistryName -Value $savePasswordRegistryValue -PropertyType DWORD -Force

# Disable Server Manager WAC prompt
Write-Host "Disabling Server Manager WAC prompt."
$RegistryPath = "HKLM:\SOFTWARE\Microsoft\ServerManager"
$Name = "DoNotPopWACConsoleAtSMLaunch"
$Value = "1"
if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Install Chocolatey
Write-Host "Installing Chocolatey"
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
Start-Sleep -Seconds 10

# Create Shortcut for Hyper-V Manager
Write-Host "Creating Shortcut for Hyper-V Manager"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\Public\Desktop"

# Create Shortcut for Failover-Cluster Manager
Write-Host "Creating Shortcut for Failover-Cluster Manager"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Failover Cluster Manager.lnk" -Destination "C:\Users\Public\Desktop"

# Create Shortcut for DNS
Write-Host "Creating Shortcut for DNS Manager"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\DNS.lnk" -Destination "C:\Users\Public\Desktop"

# Create Shortcut for Active Directory Users and Computers
Write-Host "Creating Shortcut for AD Users and Computers"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Active Directory Users and Computers.lnk" -Destination "C:\Users\Public\Desktop"

$ShortcutPath = "$env:PUBLIC\Desktop\Azure.lnk"
$TargetPath = "https://portal.azure.com"

$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $TargetPath
$Shortcut.IconLocation = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe, 0"  # Optional: Set browser icon
$Shortcut.Save()

$ShortcutPath = "$env:PUBLIC\Desktop\AzureGov.lnk"
$TargetPath = "https://portal.azure.us"

$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $TargetPath
$Shortcut.IconLocation = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe, 0"  # Optional: Set browser icon
$Shortcut.Save()

# Install Kubectl
Write-Host 'Installing kubectl'
$expression = "choco install kubernetes-cli -y --limit-output"
Invoke-Expression $expression

$endtime = Get-Date
$timeSpan = New-TimeSpan -Start $starttime -End $endtime
Write-Host
Write-Host "Successfully deployed LocalBox infrastructure." -ForegroundColor Green
Write-Host "Infrastructure deployment time was $($timeSpan.Hours):$($timeSpan.Minutes) (hh:mm)." -ForegroundColor Green

$DeploymentProgressString = 'Deployment Complete'

$tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags['DeploymentProgress'] = $DeploymentProgressString
} else {
    $tags = @{'DeploymentProgress' = $DeploymentProgressString }
}

$null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

#############################################################
# Install VSCode extensions
#############################################################

# Define the download URL for the latest VSCode system installer
$installerUrl = "https://code.visualstudio.com/sha/download?build=stable&os=win32-x64"

# Define the path to save the installer
$installerPath = "$env:TEMP\VSCodeSetup.exe"

# Download the installer
Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

# Install VSCode silently for all users
Start-Process -FilePath $installerPath -ArgumentList "/verysilent /norestart /mergetasks=!runcode" -Wait

# Clean up the installer
Remove-Item -Path $installerPath -Force

Write-Host "VSCode has been installed successfully for all users."

# Define the directory you want to add
$CodePath = "C:\Program Files\Microsoft VS Code\bin"

$CurrentLocation = (Get-Location).Path

Set-Location $CodePath

Write-Host "[$(Get-Date -Format t)] INFO: Installing VSCode extensions: " + ($LocalBoxConfig.VSCodeExtensions -join ', ') -ForegroundColor Gray
foreach ($extension in $LocalBoxConfig.VSCodeExtensions) {
    $WarningPreference = "SilentlyContinue"
    .\code --install-extension $extension 2>&1 | Out-File -Append -FilePath ($LocalBoxConfig.Paths.LogsDir + "\Tools.log")
    $WarningPreference = "Continue"
}

# Create Shortcut for VS Code
Write-Host "Creating Shortcut for VS Code"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk" -Destination "C:\Users\Public\Desktop"

Set-Location $CurrentLocation

Unregister-ScheduledTask -TaskName "LocalBoxLogonScript" -Confirm:$false
Unregister-ScheduledTask -TaskName 'Pester tests' -Confirm:$false

New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\Control Panel" -Name Desktop -Force

Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -Name Wallpaper -Value "C:\LocalBox\wallpaper.bmp"

Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -Name WallpaperStyle -Value "10"  # 10 = Fill

Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `
    -Name TileWallpaper -Value "0"

Add-Computer -ComputerName localhost -LocalCredential $localCred -DomainName $LocalBoxConfig.SDNDomainFQDN -Credential $domainCred -Force

$Items = Get-ChildItem -Path "$Env:ProgramFiles\WindowsPowerShell\Modules" | Where-Object {$_.Name -like "Az.*"}
foreach ($Item in $Items)
{
    Remove-Item -Path $Item.FullName -Recurse -Force
}

Stop-Transcript

Restart-Computer -ComputerName localhost -Force
#endregion
