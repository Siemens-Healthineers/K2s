# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

function Get-KubePath {
    $scriptRoot = $PSScriptRoot
    $kubePath = (Get-Item $scriptRoot).Parent.Parent.Parent.Parent.Parent.FullName
    return $kubePath
}

function Get-KubeBinPath {
    $kubePath = Get-KubePath
    return "$kubePath\bin"
}

function Get-KubeToolsPath {
    $kubeBinPath = Get-KubeBinPath
    return "$kubeBinPath\kube"
}

function Get-CrictlExePath {
    $kubeBinPath = Get-KubeBinPath
    $crictlExe = "$kubeBinPath\crictl.exe"
    if (-Not (Test-Path -Path $crictlExe)) {
        $crictlExeCmd = cmd /c "where crictl.exe" 2>$null
        if ($LASTEXITCODE -eq 0 -and $crictlExeCmd) {
            # Ensure we get a string and handle multiple results
            $crictlPath = $crictlExeCmd | Select-Object -First 1
            if ($crictlPath -is [string]) {
                $crictlExe = $crictlPath.Trim()
            } else {
                $crictlExe = $crictlPath.ToString().Trim()
            }
        }
        else {
            # Return default path instead of throwing error during installation
            # Write-Log "crictl.exe not found yet in k2s bin location '$crictlExe' or in PATH, returning default path for installation"
            return $crictlExe
        }       
    }
    return $crictlExe
}

function Get-K2sExePath {
    $kubePath = Get-KubePath
    $k2sExe = "$kubePath\k2s.exe"    
    return $k2sExe
}

function Get-InstallationDriveLetter {
    $kubePath = Get-KubePath
    $installationDriveLetter = ($kubePath).Split(':')[0]
    return $installationDriveLetter
}

function Get-SystemDriveLetter {
    return 'C'
}

function Test-PathPrerequisites {
    $kubePath = Get-KubePath
    $installationDirectoryType = Get-Item "$kubePath" | Select-Object -ExpandProperty LinkType
    if ($null -ne $installationDirectoryType) {
        throw "Your installation directory '$kubePath' is of type '$installationDirectoryType'. Only normal directories are supported."
    }
}

function Update-SystemPath ($Action, $Addendum) {
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

function Set-EnvVars {
    $kubePath = Get-KubePath
    Update-SystemPath -Action 'add' "$kubePath"
    Update-SystemPath -Action 'add' "$kubePath\bin"
    Update-SystemPath -Action 'add' "$kubePath\bin\kube"
    Update-SystemPath -Action 'add' "$kubePath\bin\docker"
    Update-SystemPath -Action 'add' "$kubePath\bin\containerd"
}

function Reset-EnvVars {
    $kubePath = Get-KubePath
    Update-SystemPath -Action 'remove' "$kubePath"
    Update-SystemPath -Action 'remove' "$kubePath\bin"
    Update-SystemPath -Action 'remove' "$kubePath\bin\kube"
    Update-SystemPath -Action 'remove' "$kubePath\bin\docker"
    Update-SystemPath -Action 'remove' "$kubePath\containerd" # Backward compatibility
    Update-SystemPath -Action 'remove' "$kubePath\bin\containerd"
}

<#
.SYNOPSIS
Write refresh info.

.DESCRIPTION
Write information about refersh of env variables
#>
function Write-RefreshEnvVariables {
    $kubePath = Get-KubePath
    Write-Log ' ' -Console
    Write-Log '   Update PATH environment variable for proper usage:' -Console
    Write-Log ' ' -Console
    Write-Log "   Powershell: '$kubePath\smallsetup\helpers\RefreshEnv.ps1'" -Console
    Write-Log "   Command Prompt: '$kubePath\smallsetup\helpers\RefreshEnv.cmd'" -Console
    Write-Log '   Or open new shell' -Console
    Write-Log ' ' -Console
}

Export-ModuleMember -Function Get-KubePath, Get-KubeBinPath, Get-KubeToolsPath, Get-CrictlExePath, Get-K2sExePath,
Get-InstallationDriveLetter,
Get-SystemDriveLetter,
Test-PathPrerequisites,
Update-SystemPath,
Set-EnvVars,
Write-RefreshEnvVariables,
Reset-EnvVars