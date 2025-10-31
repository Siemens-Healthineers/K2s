# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$GlobalVarsRelative = Join-Path $PSScriptRoot "..\..\..\..\..\smallsetup\common\GlobalVariables.ps1"
$GlobalVarsPath = Resolve-Path $GlobalVarsRelative -ErrorAction SilentlyContinue

if (-not $GlobalVarsPath) {
    throw "[HostSshConfig] GlobalVariables.ps1 not found at $GlobalVarsRelative"
}
. $GlobalVarsPath

function Write-SshConfig {
    $SshHost = $global:VMName
    $HostName = $global:IP_Master
    $User = $global:RemoteUserName_Master
    $Port = 22
    $IdentityFile = "C:\Users\$env:USERNAME\.ssh\K2s\id_rsa"

    $ConfigEntry = @"
Host $SshHost
    HostName $HostName
    User $User
    Port $Port
    IdentityFile $IdentityFile
    IdentitiesOnly yes
"@

    $ConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath ".ssh\config"

    if (-Not (Test-Path -Path $ConfigPath)) {
        Write-Log -Message "SSH config file not found. Creating new file at $ConfigPath."
        New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
    }

    $ExistingConfig = Get-Content -Path $ConfigPath -ErrorAction SilentlyContinue
    if ($ExistingConfig -notcontains "Host $SshHost") {
        Write-Log -Message "Adding $SshHost entry to SSH config file."
        Add-Content -Path $ConfigPath -Value $ConfigEntry
    } else {
        Write-Log -Message "$SshHost entry already exists in SSH config file. Skipping update."
    }
}

function Remove-SshConfigFile {
    $ConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath ".ssh\config"
    if (Test-Path -Path $ConfigPath) {
        Write-Log -Message "[SSHConfig] Removing SSH config file at $ConfigPath."
        Remove-Item -Path $ConfigPath -Force
    } else {
        Write-Log -Message "[SSHConfig] SSH config file not found at $ConfigPath. Nothing to remove."
    }
}
