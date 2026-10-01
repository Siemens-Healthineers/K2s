<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Preparing a Windows Worker QCOW2

The native Linux K2s host creates a new SSH key for every managed Windows
worker. A prepared QCOW2 must therefore include a startup task that imports the
public key from the K2s config drive. K2s attaches this read-only CD-ROM with
the volume label `K2SBOOT` and the file `windows-worker.pub` for every worker
start.

## Prepare the Hyper-V VM

Create and fully update a Windows 11 Hyper-V VM. Open an elevated PowerShell
session inside the guest and run the following script once:

```powershell
$ErrorActionPreference = 'Stop'

if (-not (Get-LocalUser -Name remote -ErrorAction SilentlyContinue)) {
    $password = ConvertTo-SecureString -String ([guid]::NewGuid().Guid) -AsPlainText -Force
    New-LocalUser -Name remote -Password $password -PasswordNeverExpires | Out-Null
}

$openSshCapability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($openSshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $openSshCapability = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}
if ($openSshCapability.State -ne 'Installed') {
    throw "OpenSSH Server capability is not installed. Current state: $($openSshCapability.State)"
}

if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    $installSshd = Join-Path $env:WINDIR 'System32\OpenSSH\install-sshd.ps1'
    $sshdExe = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    if (Test-Path $installSshd) {
        & $installSshd
    }
    elseif (Test-Path $sshdExe) {
        & (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe') -A
        New-Service -Name sshd -BinaryPathName "`"$sshdExe`"" -DisplayName 'OpenSSH SSH Server' -StartupType Automatic | Out-Null
    }
    else {
        throw "OpenSSH Server capability is marked Installed but sshd.exe is missing: $sshdExe. Remove and reinstall the capability before continuing."
    }
}
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    throw 'OpenSSH Server did not register the sshd service.'
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -DisplayName 'K2s Windows worker SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

# Keep the worker stable. Apply Windows updates only during planned image maintenance.
$windowsUpdatePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $windowsUpdatePolicy -Force | Out-Null
New-ItemProperty -Path $windowsUpdatePolicy -Name NoAutoUpdate -PropertyType DWord -Value 1 -Force | Out-Null
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Disabled

$scriptPath = 'C:\ProgramData\K2s\Import-WorkerSshKey.ps1'
New-Item -ItemType Directory -Path (Split-Path $scriptPath) -Force | Out-Null
@'
$ErrorActionPreference = 'Stop'
$volume = Get-Volume | Where-Object FileSystemLabel -eq 'K2SBOOT' | Select-Object -First 1
if ($null -eq $volume -or [string]::IsNullOrWhiteSpace($volume.DriveLetter)) { exit 0 }
$publicKey = Get-Content -Raw "$($volume.DriveLetter):\windows-worker.pub" -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($publicKey)) { exit 0 }
$sshDirectory = 'C:\Users\remote\.ssh'
$authorizedKeys = Join-Path $sshDirectory 'authorized_keys'
New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
Set-Content -Path $authorizedKeys -Value $publicKey.Trim() -NoNewline
icacls $sshDirectory /inheritance:r /grant 'remote:(OI)(CI)F' | Out-Null
icacls $authorizedKeys /inheritance:r /grant 'remote:F' | Out-Null
Restart-Service sshd
'@ | Set-Content -Path $scriptPath -Encoding utf8

$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName 'K2s Import Worker SSH Key' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
```

Shut down the VM. Preserve its partition style: K2s automatically boots an MBR
image with BIOS and a GPT image with UEFI. Do not generalize the image after
creating the scheduled task, because that task and the OpenSSH setup must remain
in the base image.

## Convert to QCOW2

K2s does not bundle a QCOW2 conversion utility. Install the QEMU `qemu-img`
utility on the Hyper-V host, shut down the source VM, and locate its VHDX with
`Get-VMHardDiskDrive`. Convert that VHDX from an elevated PowerShell session:

```powershell
$vhdx = (Get-VMHardDiskDrive -VMName '<Hyper-V VM name>').Path
qemu-img.exe convert -p -f vhdx -O qcow2 -o compat=1.1 $vhdx 'E:\Images\WindowsWorker-Base.qcow2'
qemu-img.exe check 'E:\Images\WindowsWorker-Base.qcow2'
```

Use the resulting image with `--windows-qcow2-path`. Before publishing it,
verify the image source VM has the required components:

```powershell
Get-ScheduledTask -TaskName 'K2s Import Worker SSH Key'
Get-Service sshd
Get-LocalUser remote
```