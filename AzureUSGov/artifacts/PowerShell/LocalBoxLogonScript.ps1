# Script runtime environment: Level-0 Azure virtual machine ("Client VM")
$ProgressPreference = "SilentlyContinue"
Set-PSDebug -Strict

#####################################################################
# Initialize the environment
#####################################################################

# Load config file
$LocalBoxConfig = Import-PowerShellDataFile -Path $Env:LocalBoxConfigFile
$Env:LocalBoxTestsDir = "$Env:LocalBoxDir\Tests"

Start-Transcript -Path "$($LocalBoxConfig.Paths.LogsDir)\LocalBoxLogonScript.log"

#####################################################################
# Setup Azure CLI and Azure PowerShell
#####################################################################

# Login to Azure CLI with service principal provided by user
Write-Header "Az CLI Login"
az cloud set --name AzureUSGovernment
az login --service-principal --username $Env:spnClientID --password=$Env:spnClientSecret --tenant $Env:spnTenantId

# Login to Azure PowerShell with service principal provided by user
$spnpassword = ConvertTo-SecureString $env:spnClientSecret -AsPlainText -Force
$spncredential = New-Object System.Management.Automation.PSCredential ($env:spnClientId, $spnpassword)
Connect-AzAccount  -Environment AzureUSGovernment -ServicePrincipal -Credential $spncredential -Tenant $env:spntenantId -Subscription $env:subscriptionId

# Add required RBAC permission required for the service principal to deploy Azure Local

Write-Header "Add required RBAC permission required for the service principal to deploy Azure Local"

$roleAssignment = Get-AzRoleAssignment -ServicePrincipalName $Env:spnClientId -Scope "/subscriptions/$Env:subscriptionId/resourceGroups/$Env:resourceGroup" -RoleDefinitionName "Key Vault Administrator" -ErrorAction SilentlyContinue
if ($null -eq $roleAssignment) {
    New-AzRoleAssignment -RoleDefinitionName "Key Vault Administrator" -ServicePrincipalName $Env:spnClientId -Scope "/subscriptions/$Env:subscriptionId/resourceGroups/$Env:resourceGroup"
}

$roleAssignment = Get-AzRoleAssignment -ServicePrincipalName $Env:spnClientId -Scope "/subscriptions/$Env:subscriptionId/resourceGroups/$Env:resourceGroup" -RoleDefinitionName "Storage Account Contributor" -ErrorAction SilentlyContinue
if ($null -eq $roleAssignment) {
    New-AzRoleAssignment -RoleDefinitionName "Storage Account Contributor" -ServicePrincipalName $Env:spnClientId -Scope "/subscriptions/$Env:subscriptionId/resourceGroups/$Env:resourceGroup"
}

#####################################################################
# Configure VNet DNS servers
#####################################################################
$dnsServers = @("$($LocalBoxConfig.vmDNS)", "168.63.129.16")
$VNet = Get-AzVirtualNetwork -ResourceGroupName $env:resourceGroup
$VNet.DhcpOptions.DnsServers = $dnsServers
Set-AzVirtualNetwork -VirtualNetwork $vnet

#############################################################
# Remove registry keys that are used to automatically logon the user (only used for first-time setup)
#############################################################

$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$keys = @("AutoAdminLogon", "DefaultUserName", "DefaultPassword")

foreach ($key in $keys) {
    try {
        $property = Get-ItemProperty -Path $registryPath -Name $key -ErrorAction Stop
        Remove-ItemProperty -Path $registryPath -Name $key
        Write-Host "Removed registry key that are used to automatically logon the user: $key"
    } catch {
        Write-Verbose "Key $key does not exist."
    }
}

#############################################################
# Configure Windows Terminal as the default terminal application
#############################################################

$registryPath = "HKCU:\Console\%%Startup"

if (Test-Path $registryPath) {
    Set-ItemProperty -Path $registryPath -Name "DelegationConsole" -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-ItemProperty -Path $registryPath -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
} else {
    New-Item -Path $registryPath -Force | Out-Null
    Set-ItemProperty -Path $registryPath -Name "DelegationConsole" -Value "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
    Set-ItemProperty -Path $registryPath -Name "DelegationTerminal" -Value "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"
}

#############################################################
# Install VSCode extensions
#############################################################

Write-Host "[$(Get-Date -Format t)] INFO: Installing VSCode extensions: " + ($LocalBoxConfig.VSCodeExtensions -join ', ') -ForegroundColor Gray
foreach ($extension in $LocalBoxConfig.VSCodeExtensions) {
    $WarningPreference = "SilentlyContinue"
    code --install-extension $extension 2>&1 | Out-File -Append -FilePath ($LocalBoxConfig.Paths.LogsDir + "\Tools.log")
    $WarningPreference = "Continue"
}

#####################################################################
# Configure virtualization infrastructure
#####################################################################

# Configure storage pools and data disks
Write-Header "Configuring storage"
New-StoragePool -FriendlyName AzLocalPool -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
$disks = Get-StoragePool -FriendlyName AzLocalPool -IsPrimordial $False | Get-PhysicalDisk
$diskNum = $disks.Count
New-VirtualDisk -StoragePoolFriendlyName AzLocalPool -FriendlyName AzLocalDisk -ResiliencySettingName Simple -NumberOfColumns $diskNum -UseMaximumSize
$vDisk = Get-VirtualDisk -FriendlyName AzLocalDisk
if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
    $vDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter $LocalBoxConfig.HostVMDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLocalData -AllocationUnitSize 64KB -FileSystem NTFS
}
elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
    $vDisk | Get-Disk | New-Partition -DriveLetter $LocalBoxConfig.HostVMDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel AzLocalData -AllocationUnitSize 64KB -FileSystem NTFS
}

#Changing to Jumpstart LocalBox wallpaper

Write-Header "Changing wallpaper"

# bmp file is required for BGInfo
function Convert-JSImageToBitMap {
    param (
        $SourceFilePath,
        $DestinationFilePath
    )
    [Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
    $file = Get-Item $SourceFilePath
    $convertfile = new-object System.Drawing.Bitmap($file.Fullname)
    $convertfile.Save($DestinationFilePath, "bmp")
}

function Set-JSDesktopBackground {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

$code = @'
    using System.Runtime.InteropServices;
    namespace Win32{

        public class Wallpaper{
            [DllImport("user32.dll", CharSet=CharSet.Auto)]
            static extern int SystemParametersInfo (int uAction , int uParam , string lpvParam , int fuWinIni) ;

            public static void SetWallpaper(string thePath){
                SystemParametersInfo(20,0,thePath,3);
            }
        }
    }
'@

Add-Type $code
[Win32.Wallpaper]::SetWallpaper($ImagePath)

}

Convert-JSImageToBitMap -SourceFilePath "$Env:LocalBoxDir\wallpaper.png" -DestinationFilePath "$Env:LocalBoxDir\wallpaper.bmp"

Set-JSDesktopBackground -ImagePath "$Env:LocalBoxDir\wallpaper.bmp"

Write-Header "Running tests to verify infrastructure"
Stop-Transcript

# Build Azure Local cluster
& "$Env:LocalBoxDir\New-LocalBoxCluster.ps1"
