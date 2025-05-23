$RequestInf = @"
[Version]
Signature="`$Windows NT$"

[NewRequest]
Subject = "CN=$($LocalBoxConfig.WACVMName).$($LocalBoxConfig.SDNDomainFQDN)"
Exportable = True
KeyLength = 2048
KeySpec = 1
KeyUsage = 0xA0
MachineKeySet = True
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
SMIME = FALSE
RequestType = CMC
FriendlyName = "LocalBox Windows Admin Cert"

[Strings]
szOID_SUBJECT_ALT_NAME2 = "2.5.29.17"
szOID_ENHANCED_KEY_USAGE = "2.5.29.37"
szOID_PKIX_KP_SERVER_AUTH = "1.3.6.1.5.5.7.3.1"
szOID_PKIX_KP_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"
[Extensions]
%szOID_SUBJECT_ALT_NAME2% = "{text}dns=azlmgmt.jumpstart.local"
%szOID_ENHANCED_KEY_USAGE% = "{text}%szOID_PKIX_KP_SERVER_AUTH%,%szOID_PKIX_KP_CLIENT_AUTH%"
[RequestAttributes]
CertificateTemplate= WebServer
"@

New-Item C:\WACCert -ItemType Directory -Force | Out-Null
Set-Content -Value $RequestInf -Path C:\WACCert\WACCert.inf -Force | Out-Null

Write-Host "Requesting and installing SSL Certificate on $ENV:Computername"

# Get the CA Name
$CertDump = certutil -dump
$ca = ((((($CertDump.Replace('`', "")).Replace("'", "")).Replace(":", "=")).Replace('\', "")).Replace('"', "") | ConvertFrom-StringData).Name
$CertAuth = 'jumpstart.local' + '\' + $ca

Write-Host "CA is: $ca"
Write-Host "Certificate Authority is: $CertAuth"
Write-Host "Certdump is $CertDump"

# Request and Accept SSL Certificate
Set-Location C:\WACCert
certreq -q -f -new WACCert.inf WACCert.req
certreq -q -config $CertAuth -attrib "CertificateTemplate:webserver" -submit WACCert.req  WACCert.cer
certreq -q -accept WACCert.cer
certutil -q -store my

Set-Location 'C:\'
Remove-Item C:\WACCert -Recurse -Force

# Download Windows Admin Center
$parameters = @{
     Source = "https://aka.ms/WACdownload"
     Destination = "C:\Lab Files\WindowsAdminCenter.exe"
}

Start-BitsTransfer @parameters

# Install Windows Admin Center
$pfxThumbPrint = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object { $_.FriendlyName -match "LocalBox Windows Admin Cert" }).Thumbprint
Write-Host "Thumbprint: $pfxThumbPrint"
Write-Host "WACPort: 443"
$WindowsAdminCenterGateway = "https://azlmgmt.jumpstart.local"
Write-Host $WindowsAdminCenterGateway
Write-Host "Installing and Configuring Windows Admin Center"
$PathResolve = Resolve-Path -Path 'C:\Lab Files\WindowsAdminCenter*.exe'
$arguments = "/quiet /port:443 /sslthumbprint:$pfxThumbPrint /norestart"
Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru | Wait-Process

# Install Chocolatey
Write-Host "Installing Chocolatey"
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
Start-Sleep -Seconds 10

# Install Azure PowerShell
Write-Host 'Installing Az PowerShell'
$expression = "choco install az.powershell -y --limit-output"
Invoke-Expression $expression

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

# Set Network Profiles
Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq "Public" } | Set-NetConnectionProfile -NetworkCategory Private | Out-Null

# Install Kubectl
Write-Host 'Installing kubectl'
$expression = "choco install kubernetes-cli -y --limit-output"
Invoke-Expression $expression

# Create a shortcut for Windows Admin Center
Write-Host "Creating Shortcut for Windows Admin Center"
$TargetPath = "https://azlmgmt.jumpstart.local"
$ShortcutFile = "C:\Users\Public\Desktop\Windows Admin Center.url"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetPath
$Shortcut.Save()