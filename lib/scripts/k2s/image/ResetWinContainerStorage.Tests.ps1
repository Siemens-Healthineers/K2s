# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\ResetWinContainerStorage.ps1"
    $scriptContent = (Get-Content -Path $scriptPath | Where-Object { $_ -notmatch '^#Requires\b' }) -join [Environment]::NewLine

    # Stub external module functions consumed by the script.
    function global:Initialize-Logging { }
    function global:Write-Log { param([Parameter(ValueFromPipeline = $true)]$Message, [switch]$Console, [switch]$Error) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:New-Error { param($Severity, $Code, $Message) return [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message } }
    function global:Get-ErrCodeWrongSetupType { return 'wrong-setup-type' }
    function global:Get-ErrCodeSystemRunning { return 'system-running' }
    function global:Get-ErrCodeUserCancellation { return 'user-cancellation' }
    function global:Get-SetupInfo { return [PSCustomObject]@{ Name = 'k2s'; LinuxOnly = $false } }
    function global:Get-RunningState { param($SetupName) return [PSCustomObject]@{ IsRunning = $false } }
    function global:Get-KubeBinPath { return 'C:\k\bin' }
    function global:Get-StorageLocalDrive { return 'C:' }
    function global:Get-StorageLocalFolderName { return '\' }

    function Invoke-ResetWinContainerStorageScript {
        param(
            [string] $Containerd,
            [string] $Docker
        )

        $invokeParams = @{
            Force = $true # skip the interactive Read-Host prompt
        }
        if ($PSBoundParameters.ContainsKey('Containerd')) {
            $invokeParams.Containerd = $Containerd
        }
        if ($PSBoundParameters.ContainsKey('Docker')) {
            $invokeParams.Docker = $Docker
        }

        & ([scriptblock]::Create($scriptContent)) @invokeParams
    }
}

Describe 'ResetWinContainerStorage.ps1' -Tag 'unit', 'ci', 'image' {

    BeforeEach {
        Mock -CommandName Initialize-Logging { }
        Mock -CommandName Write-Log { }
        Mock -CommandName Send-ToCli { }
        Mock -CommandName Get-SetupInfo { return [PSCustomObject]@{ Name = 'k2s'; LinuxOnly = $false } }
        Mock -CommandName Get-RunningState { return [PSCustomObject]@{ IsRunning = $false } }
        # Docker daemon not running -> Get-Process returns nothing
        Mock -CommandName Get-Process { return $null }
        # Never actually touch the file system: report nothing to clean up so
        # the internal cleanup routine is skipped, but capture the resolved path.
        Mock -CommandName Test-Path { return $false }
        Mock -CommandName Get-StorageLocalDrive { return 'C:' }
        Mock -CommandName Get-StorageLocalFolderName { return '\' }
    }

    Context 'Containerd path resolution when no explicit path is provided' {

        It 'resolves the configured custom storage path as <drive><folder>\containerd' {
            Mock -CommandName Get-StorageLocalDrive { return 'D:' }
            Mock -CommandName Get-StorageLocalFolderName { return '\Somaris\appdata' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'D:\Somaris\appdata\containerd' }
        }

        It 'resolves the default install to C:\containerd' {
            Mock -CommandName Get-StorageLocalDrive { return 'C:' }
            Mock -CommandName Get-StorageLocalFolderName { return '\' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'C:\containerd' }
        }

        It 'falls back to C:\containerd when the storage helper throws' {
            Mock -CommandName Get-StorageLocalDrive { throw 'no storage config' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'C:\containerd' }
        }
    }

    Context 'Explicit containerd path takes precedence' {

        It 'uses the explicit path and does not call the storage helpers' {
            Invoke-ResetWinContainerStorageScript -Containerd 'E:\Temp\Containerd'

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'E:\Temp\Containerd' }
            Should -Invoke Get-StorageLocalDrive -Exactly 0
            Should -Invoke Get-StorageLocalFolderName -Exactly 0
        }
    }
}

