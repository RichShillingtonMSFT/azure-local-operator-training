$RequestInf = @"
[Version]
Signature="`$Windows NT$"

[NewRequest]
Subject = "CN=$($ENV:Computername).$($env:USERDNSDOMAIN)"
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
%szOID_SUBJECT_ALT_NAME2% = "{text}dns=$($ENV:Computername).$($env:USERDNSDOMAIN)"
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
     Destination = "C:\LabFiles\WAC\WindowsAdminCenter.exe"
}

Start-BitsTransfer @parameters

# Install Windows Admin Center
$pfxSubjectName = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object { $_.FriendlyName -match "LocalBox Windows Admin Cert" }).SubjectName.Name
$pfxThumbPrint = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object { $_.FriendlyName -match "LocalBox Windows Admin Cert" }).Thumbprint
Write-Host "Thumbprint: $pfxThumbPrint"
Write-Host "WACPort: 443"
$WindowsAdminCenterGateway = "https://$($ENV:Computername).$($env:USERDNSDOMAIN)"
Write-Host $WindowsAdminCenterGateway
Write-Host "Installing and Configuring Windows Admin Center"
$PathResolve = Resolve-Path -Path 'C:\LabFiles\WAC\WindowsAdminCenter*.exe'
$arguments = "/VERYSILENT /port:443 /ALLUSERS /sslthumbprint:$pfxThumbPrint /norestart"
Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru | Wait-Process
Import-Module "$env:ProgramFiles\WindowsAdminCenter\PowerShellModules\Microsoft.WindowsAdminCenter.Configuration"
Set-WACCertificateSubjectName -Thumbprint $pfxThumbPrint
Set-WACCertificateAcl -SubjectName $pfxSubjectName -Verbose
Restart-Service -Name WindowsAdminCenter
