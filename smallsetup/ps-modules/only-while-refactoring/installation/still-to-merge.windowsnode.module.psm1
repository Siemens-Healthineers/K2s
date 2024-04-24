# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$temporaryPathModule = "$PSScriptRoot\still-to-merge.path.module.psm1"

Import-Module $temporaryPathModule

function Get-WindowsNodeArtifactsDirectory {
    return "$(Get-InstallationPath)\bin\windowsnode"
}


function Get-KubeletConfigDirectory {
    return "$(Get-SystemDriveLetter):\var\lib\kubelet"
}

function Get-KubectlExecutable {
    return "$(Get-ExecutablesPath)\kubectl.exe"
}

function Get-DockerExecutable {
    return "$(Get-DockerPath)\docker.exe"
}

Export-ModuleMember -Function Get-WindowsNodeArtifactsDirectory, Get-KubeletConfigDirectory, Get-KubectlExecutable, Get-DockerExecutable
