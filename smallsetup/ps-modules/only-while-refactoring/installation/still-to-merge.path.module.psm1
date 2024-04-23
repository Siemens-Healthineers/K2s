# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\..\log\log.module.psm1"

Import-Module $logModule

function Get-InstallationPath {
    $installationPath = GetKubePath
    return $installationPath
}

function GetKubePath {
    $scriptRoot = $PSScriptRoot
    $kubePath = (Get-Item $scriptRoot).Parent.Parent.Parent.Parent.FullName
    return $kubePath
}

function UpdateSystemPath ($Action, $Addendum) {
    $regLocation = 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment'
    $path = (Get-ItemProperty -Path $regLocation -Name PATH).path

    # Add an item to PATH
    if ($Action -eq 'add') {
        $path = $path + [IO.Path]::PathSeparator + $Addendum
        $path = ( $path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path

        $env:Path = $env:Path + [IO.Path]::PathSeparator + $Addendum
        $env:Path = ( $env:Path -split [IO.Path]::PathSeparator | Select-Object -Unique ) -join [IO.Path]::PathSeparator

        Write-Verbose "Added $Addendum to PATH variable"
    }

    # Remove an item from PATH
    if ($Action -eq 'remove') {
        $path = ($path.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ne "$Addendum" }) -join [IO.Path]::PathSeparator
        Set-ItemProperty -Path $regLocation -Name PATH -Value $path
    }
}

function Set-EnvironmentPaths {
    $kubePath = GetKubePath
    UpdateSystemPath -Action 'add' "$kubePath"
    UpdateSystemPath -Action 'add' "$kubePath\bin"
    UpdateSystemPath -Action 'add' "$kubePath\bin\exe"
    UpdateSystemPath -Action 'add' "$kubePath\bin\docker"
    UpdateSystemPath -Action 'add' "$kubePath\bin\containerd"
}

function Reset-EnvironmentPaths {
    UpdateSystemPath -Action 'remove' "$kubePath"
    UpdateSystemPath -Action 'remove' "$kubePath\bin"
    UpdateSystemPath -Action 'remove' "$kubePath\bin\exe"
    UpdateSystemPath -Action 'remove' "$kubePath\bin\docker"
    UpdateSystemPath -Action 'remove' "$kubePath\containerd" # Backward compatibility
    UpdateSystemPath -Action 'remove' "$kubePath\bin\containerd"
}

function Write-RefreshEnvironmentPathsMessage {
    Write-Log ' ' -Console
    Write-Log '   Update PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$global:KubernetesPath\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$global:KubernetesPath\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

Export-ModuleMember -Function Set-EnvironmentPaths, Reset-EnvironmentPaths, Write-RefreshEnvironmentPathsMessage, Get-InstallationPath