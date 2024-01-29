# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    return "$kubeBinPath\exe"   
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
    Update-SystemPath -Action 'add' "$kubePath\bin\exe"
    Update-SystemPath -Action 'add' "$kubePath\bin\docker"
    Update-SystemPath -Action 'add' "$kubePath\bin\containerd"
}

function Reset-EnvVars {
    Update-SystemPath -Action 'remove' "$kubePath"
    Update-SystemPath -Action 'remove' "$kubePath\bin"
    Update-SystemPath -Action 'remove' "$kubePath\bin\exe"
    Update-SystemPath -Action 'remove' "$kubePath\bin\docker"
    Update-SystemPath -Action 'remove' "$kubePath\containerd" # Backward compatibility
    Update-SystemPath -Action 'remove' "$kubePath\bin\containerd"
}

Export-ModuleMember -Function Get-KubePath, Get-KubeBinPath, Get-KubeToolsPath,
Get-InstallationDriveLetter,
Get-SystemDriveLetter,
Test-PathPrerequisites,
Update-SystemPath,
Set-EnvVars,
Reset-EnvVars