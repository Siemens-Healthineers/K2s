# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -Version 5.1

BeforeAll {
    $script:ScriptPath = "$PSScriptRoot\Invoke-VhdxCompaction.ps1"

    function global:Initialize-Logging { param([switch]$ShowLogs) }
    function global:Get-KubePath { return 'C:\k2s' }
    function global:Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
    function global:Get-ConfigWslFlag { return $false }
    function global:Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
    function global:Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    function global:Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch]$IgnoreErrors) return [PSCustomObject]@{ Output = @('fstrim done') } }
    function global:Write-Log { param([string]$Message, [switch]$Console) }

    function New-MockVm {
        param([string]$Name = 'kubemaster', [string]$State = 'Off')
        return [PSCustomObject]@{ Name = $Name; State = $State }
    }

    function New-MockDisk {
        param([string]$Path = 'C:\VMs\KubeMaster.vhdx', [int]$ControllerNumber = 0, [int]$ControllerLocation = 0)
        return [PSCustomObject]@{ Path = $Path; ControllerNumber = $ControllerNumber; ControllerLocation = $ControllerLocation }
    }
}

Describe 'Invoke-VhdxCompaction' -Tag 'unit', 'ci', 'compact' {

    Describe 'Pre-condition: K2s not installed' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return $null }
            Mock Write-Log {}
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when K2s is not installed' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*not installed*' } -Times 1
        }
    }

    Describe 'Pre-condition: WSL installation' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $true }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 on WSL installation' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*WSL*' } -Times 1
        }
    }

    Describe 'Pre-condition: VM not found' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return $null }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when VM does not exist' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*not found*" } -Times 1
        }
    }

    Describe 'Pre-condition: VM in intermediate state' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when VM is in Saved state' {
            Mock Get-VM { return New-MockVm -State 'Saved' }
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*Saved*" } -Times 1
        }

        It 'exits with code 1 when VM is in Paused state' {
            Mock Get-VM { return New-MockVm -State 'Paused' }
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*Paused*" } -Times 1
        }

        It 'exits with code 1 when VM is in Starting state' {
            Mock Get-VM { return New-MockVm -State 'Starting' }
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*Starting*" } -Times 1
        }

        It 'exits with code 1 when VM is in Stopping state' {
            Mock Get-VM { return New-MockVm -State 'Stopping' }
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*Stopping*" } -Times 1
        }

        It 'exits with code 1 when VM is in FastSaved state' {
            Mock Get-VM { return New-MockVm -State 'FastSaved' }
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like "*FastSaved*" } -Times 1
        }
    }

    Describe 'Pre-condition: No hard disk found on VM' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return $null }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when no hard disk drive is attached' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Could not determine VHDX path*' } -Times 1
        }
    }

    Describe 'Pre-condition: VHDX file missing from disk' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk -Path 'C:\VMs\Missing.vhdx' }
            Mock Test-Path { return $false }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when VHDX file does not exist on disk' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*VHDX file not found*' } -Times 1
        }
    }

    Describe 'Pre-condition: VM has snapshots' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @( [PSCustomObject]@{ Name = 'snap1' }, [PSCustomObject]@{ Name = 'snap2' } ) }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 and reports snapshot count' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*snapshot*' } -Times 1
        }
    }

    Describe 'Pre-condition: Insufficient host free disk space' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 1GB } }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with code 1 when host has insufficient free space' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Insufficient host disk space*' } -Times 1
        }
    }

    Describe 'Pre-condition: VHDX already mounted (stale from previous run)' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $true } }
            Mock Dismount-VHD {}
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'dismounts the stale mount before proceeding' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Dismount-VHD -Times 1
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*appears attached*' } -Times 1
        }
    }

    Describe 'Multiple VHDs: picks primary OS disk' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive {
                return @(
                    (New-MockDisk -Path 'C:\VMs\Data.vhdx'  -ControllerNumber 0 -ControllerLocation 1),
                    (New-MockDisk -Path 'C:\VMs\KubeMaster.vhdx' -ControllerNumber 0 -ControllerLocation 0)
                )
            }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'logs that multiple disks exist and picks the lowest-indexed one' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*2 disks*' } -Times 1
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*KubeMaster.vhdx*' } -Times 1
        }
    }

    Describe 'Happy path: cluster already stopped, no-restart' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'mounts, optimizes, and dismounts VHDX without stopping or starting cluster' {
            { & $script:ScriptPath -NoRestart } | Should -Not -Throw
            Assert-MockCalled Mount-VHD    -Times 1
            Assert-MockCalled Optimize-VHD -Times 1
            Assert-MockCalled Dismount-VHD -Times 1
        }

        It 'logs compaction completed successfully' {
            { & $script:ScriptPath -NoRestart } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*compaction completed successfully*' } -Times 1
        }

        It 'logs the compaction results section' {
            { & $script:ScriptPath -NoRestart } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Compaction Results*' } -Times 1
        }
    }

    Describe 'Failure: Mount-VHD fails' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD { throw 'Mount failed' }
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'logs mount error' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Failed to mount VHDX*' } -Times 1
        }
    }

    Describe 'Failure: Optimize-VHD fails' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD { throw 'Optimize failed' }
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'dismounts VHDX after optimization failure' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Dismount-VHD -Times 1
        }

        It 'logs optimization error' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Optimization failed*' } -Times 1
        }

        It 'logs dismount after failure' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*dismounted after optimization failure*' } -Times 1
        }
    }

    Describe 'Failure: Dismount-VHD fails after optimization' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD { throw 'Dismount failed' }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'warns about failed dismount but does not crash' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Failed to dismount VHDX*' } -Times 1
        }
    }

    Describe 'User cancellation at confirmation prompt' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Running' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @() } }
            Mock Read-Host { return 'n' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits cleanly and never mounts VHDX when user answers n' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Mount-VHD    -Times 0
            Assert-MockCalled Optimize-VHD -Times 0
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*cancelled by user*' } -Times 1
        }
    }

    Describe 'Yes flag bypasses confirmation prompt' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            $script:stopCount = 0
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM {
                if ($script:stopCount -eq 0) { $script:stopCount++; return New-MockVm -State 'Running' }
                return New-MockVm -State 'Off'
            }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @() } }
            Mock Read-Host { return 'n' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'never calls Read-Host when -Yes is specified' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Read-Host -Times 0
        }
    }

    Describe 'Get-VHD unavailable: warning logged and compaction continues' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { throw 'Get-VHD not available' }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'logs a warning but still proceeds to mount and optimize' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Could not inspect VHD mount state*' } -Times 1
            Assert-MockCalled Mount-VHD    -Times 1
            Assert-MockCalled Optimize-VHD -Times 1
        }
    }

    Describe 'Get-PSDrive unavailable: warning logged and compaction continues' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { throw 'Drive not found' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'logs a warning but still mounts and optimizes VHDX' {
            { & $script:ScriptPath } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Could not determine free disk space*' } -Times 1
            Assert-MockCalled Mount-VHD    -Times 1
            Assert-MockCalled Optimize-VHD -Times 1
        }
    }
}

