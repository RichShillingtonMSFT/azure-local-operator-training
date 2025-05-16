Get-WindowsImage -ImagePath "E:\sources\install.wim"

New-VHD -Path "C:\VHDs\AzL2503.vhdx" -SizeBytes 127GB -Dynamic
Mount-VHD -Path "C:\VHDs\AzL2503.vhdx"
Initialize-Disk -Number 1
New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "OSDisk"
dism /Apply-Image /ImageFile:E:\sources\install.wim /Index:1 /ApplyDir:D:\
bcdboot D:\Windows /s D: /f UEFI





Get-DiskImage -ImagePath 