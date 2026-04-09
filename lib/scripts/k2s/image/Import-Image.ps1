# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Import image from filesystem

.DESCRIPTION
Import image from filesystem

.PARAMETER ImagePath
The image path of the image to be imported

.PARAMETER ImageDir
The directory of the images to be imported

.PARAMETER Windows
Image to import is a Windows image

.PARAMETER DockerArchive
Import a docker archive (default OCI archive)

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Import windows container image from C:\temp\tmp.tar
PS> .\Import-Image.ps1 -ImagePath "C:\temp\tmp.tar" -Windows

.EXAMPLE
# Import all container image from directory C:\temp
PS> .\Import-Image.ps1 -ImageDir "C:\temp"
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImagePath,
    [parameter(Mandatory = $false)]
    [string] $ImageDir,
    [parameter(Mandatory = $false)]
    [string] $Nodes = '',
    [parameter(Mandatory = $false)]
    [switch] $Windows = $false,
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

if (-not (Initialize-ImageScriptContext -ShowLogs:$ShowLogs -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType)) {
    return
}

$images = @()
if ($ImagePath -ne '') {
    $images += $ImagePath
    Write-Log "Importing image $ImagePath. This can take some time..."
}
elseif ($ImageDir -ne '') {
    $files = Get-Childitem -recurse $ImageDir | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from $ImageDir. This can take some time..."
}

$nodeList = Resolve-NodeList -Nodes $Nodes

if ($nodeList.Count -eq 0) {
    # Default routing: Windows local host or Linux control-plane
    if ($Windows) {
        foreach ($image in $images) {
            $importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $image
            if ($importSuccess) {
                Write-Log "$image imported successfully"
            }
        }
    }
    else {
        foreach ($image in $images) {
            Copy-ToControlPlaneViaSSHKey $image '/tmp/import.tar'

            if (!$?) {
                Write-Error "Image $image could not be copied to KubeMaster"
            }

            if (!$DockerArchive) {
                (Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' -NoLog).Output | Write-Log
            }
            else {
                (Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' -NoLog).Output | Write-Log
            }

            if ($?) {
                Write-Log "Image archive $image imported successfully."
            }

            (Invoke-CmdOnControlPlaneViaSSHKey 'cd /tmp && sudo rm -rf import.tar' -NoLog).Output | Write-Log
        }
    }
}
else {
    # Node-specific routing
    foreach ($nodeName in $nodeList) {
        $nodeInfo = Resolve-ImageNode -NodeName $nodeName
        if ($null -eq $nodeInfo) {
            Write-Log "[Import] Node '$nodeName' could not be resolved, skipping" -Console
            continue
        }

        Write-Log "[Import] Targeting node '$nodeName' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))" -Console

        foreach ($image in $images) {
            Write-Log "[Import] Importing '$image' on '$nodeName'"

            switch ($nodeInfo.Kind) {
                'ControlPlane' {
                    Copy-ToControlPlaneViaSSHKey $image '/tmp/import.tar'
                    if (!$?) {
                        Write-Error "Image $image could not be copied to control-plane '$nodeName'"
                    }
                    $pullCmd = if (!$DockerArchive) { 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' } else { 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' }
                    (Invoke-CmdOnControlPlaneViaSSHKey $pullCmd -NoLog).Output | Write-Log
                    if ($?) { Write-Log "Image archive $image imported successfully on '$nodeName'." }
                    (Invoke-CmdOnControlPlaneViaSSHKey 'cd /tmp && sudo rm -rf import.tar' -NoLog).Output | Write-Log
                }
                'LinuxWorker' {
                    Copy-ToRemoteComputerViaSshKey -Source $image -Target '/tmp/import.tar' -UserName $nodeInfo.Username -IpAddress $nodeInfo.IpAddress
                    if (!$?) {
                        Write-Error "Image $image could not be copied to Linux worker '$nodeName'"
                    }
                    $pullCmd = if (!$DockerArchive) { 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' } else { 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' }
                    (Invoke-CmdOnVmViaSSHKey $pullCmd -IpAddress $nodeInfo.IpAddress -UserName $nodeInfo.Username -NoLog).Output | Write-Log
                    if ($?) { Write-Log "Image archive $image imported successfully on '$nodeName'." }
                    (Invoke-CmdOnVmViaSSHKey 'cd /tmp && sudo rm -rf import.tar' -IpAddress $nodeInfo.IpAddress -UserName $nodeInfo.Username -NoLog).Output | Write-Log
                }
                'LocalWindows' {
                    $importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $image
                    if ($importSuccess) {
                        Write-Log "$image imported successfully on local Windows host"
                    }
                }
                'WindowsWorker' {
                    Write-Log "[Import] Importing Windows image on VM worker '$nodeName'" -Console
                    $session = $null
                    try {
                        $session = Open-RemoteSession -VmName $nodeName -VmPwd (Get-DefaultTempPwd) -NoLog
                        $remoteTempPath = 'C:\Windows\Temp\import.tar'
                        Copy-Item -Path $image -Destination $remoteTempPath -ToSession $session -Force
                        $importSuccess = Invoke-Command -Session $session -ArgumentList $remoteTempPath -ScriptBlock {
                            param($remoteImagePath)
                            $remoteCtrCmd = Get-Command ctr.exe -ErrorAction SilentlyContinue
                            $remoteCtrPath = if ($remoteCtrCmd) { $remoteCtrCmd.Source } else { 'ctr.exe' }
                            & $remoteCtrPath -n k8s.io images import $remoteImagePath 2>&1
                            return ($LASTEXITCODE -eq 0)
                        }
                        if ($importSuccess) {
                            Write-Log "$image imported successfully on Windows worker '$nodeName'"
                        }
                        else {
                            Write-Error "Failed to import $image on Windows worker '$nodeName'"
                        }
                        Invoke-Command -Session $session -ArgumentList $remoteTempPath -ScriptBlock {
                            param($path) Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                        }
                    }
                    finally {
                        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                    }
                }
                default {
                    Write-Log "[Import] Unknown node kind '$($nodeInfo.Kind)' for '$nodeName', skipping" -Console
                }
            }
        }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}