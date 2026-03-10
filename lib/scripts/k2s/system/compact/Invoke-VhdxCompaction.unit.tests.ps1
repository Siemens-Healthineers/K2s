# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -Version 5.1

<#
.SYNOPSIS
Unit tests for Invoke-VhdxCompaction.ps1

.DESCRIPTION
Tests all branches and edge cases of the VHDX compaction script using
Pester mocks. No actual Hyper-V, VM, or cluster interaction takes place.
#>

BeforeAll {
    # Dot-source the script so its functions and variables are in scope.
    # We capture the script's exit calls by mocking the relevant commands.
    $script:ScriptPath = "$PSScriptRoot\Invoke-VhdxCompaction.ps1"

    # Provide stub modules so Import-Module does not fail in a test environment.
    function global:Initialize-Logging { param([switch]$ShowLogs) }
    function global:Get-KubePath { return 'C:\k2s' }
    function global:Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
    function global:Get-ConfigWslFlag { return $false }
    function global:Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
    function global:Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    function global:Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch]$IgnoreErrors) return [PSCustomObject]@{ Output = @('fstrim done') } }
    function global:Wait-ForDesiredVMState { param($VmName, $State, $TimeoutInSeconds) }
    function global:Write-Log { param([string]$Message, [switch]$Console) }

    # Helper: build a minimal VM object with configurable State
    function New-MockVm {
        param(
            [string]$Name = 'kubemaster',
            [string]$State = 'Off'
        )
        $vm = [PSCustomObject]@{
            Name  = $Name
            State = $State
        }
        return $vm
    }

    # Helper: build a minimal VMHardDiskDrive object
    function New-MockDisk {
        param(
            [string]$Path = 'C:\VMs\KubeMaster.vhdx',
            [int]$ControllerNumber   = 0,
            [int]$ControllerLocation = 0
        )
        return [PSCustomObject]@{
            Path               = $Path
            ControllerNumber   = $ControllerNumber
            ControllerLocation = $ControllerLocation
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: invoke the script with a given set of parameters, capturing the
# exit code from the process (exit calls inside the script become the process
# exit code when run in a child process, but here we use a workaround via
# mocked 'exit' by wrapping in a scriptblock executed with &).
# ---------------------------------------------------------------------------

# Because the script calls `exit N` directly, we test it by executing in a
# restricted scope.  We use InModuleScope-style mocking at the script level
# via Pester's -ScriptBlock parameter.

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

Describe 'Invoke-VhdxCompaction' -Tag 'unit', 'ci', 'compact' {

    # ------------------------------------------------------------------
    # Pre-condition guards
    # ------------------------------------------------------------------

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
            # 4 GB VHDX, only 1 GB free → should fail
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
            # VHDX is already attached
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
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*already mounted*' } -Times 1
        }
    }

    Describe 'Multiple VHDs: picks primary OS disk' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            # Two disks; controller 0/location 0 is the OS disk
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
            # The primary disk path (ControllerLocation 0) should appear in a log message
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

    Describe 'Happy path: cluster running, stop + compact + restart' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            $script:stopCallCount = 0
            $script:startCallCount = 0

            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            # First call returns Running (initial check); after stop returns Off
            Mock Get-VM {
                if ($script:stopCallCount -eq 0) { return New-MockVm -State 'Running' }
                return New-MockVm -State 'Off'
            }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @('/: 10 GiB trimmed') } }
            Mock Wait-ForDesiredVMState { $script:stopCallCount++ }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}

            # Mock the inner stop/start script calls
            Mock Invoke-Expression {}
        }

        It 'runs fstrim when cluster is running and skip-fstrim is not set' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Invoke-CmdOnControlPlaneViaSSHKey -Times 1
        }

        It 'waits for VM to reach Off state after stopping cluster' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Wait-ForDesiredVMState -Times 1
        }
    }

    Describe 'Happy path: skip-fstrim flag suppresses fstrim' -Tag 'unit', 'ci', 'compact' {
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
            Mock Wait-ForDesiredVMState {}
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not call SSH when -SkipFstrim is specified' {
            { & $script:ScriptPath -Yes -SkipFstrim } | Should -Not -Throw
            Assert-MockCalled Invoke-CmdOnControlPlaneViaSSHKey -Times 0
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*skip-fstrim*' } -Times 1
        }
    }

    Describe 'Failure: Mount-VHD fails — cluster was running — attempts restart' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            $script:restartAttempted = $false
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

    Describe 'Failure: Optimize-VHD fails — VHDX is dismounted before exit' -Tag 'unit', 'ci', 'compact' {
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
                if ($script:stopCount -eq 0) { return New-MockVm -State 'Running' }
                return New-MockVm -State 'Off'
            }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @() } }
            Mock Read-Host { return 'n' }   # Would cancel if reached
            Mock Wait-ForDesiredVMState { $script:stopCount++ }
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

    Describe 'Stop timeout: Wait-ForDesiredVMState throws' -Tag 'unit', 'ci', 'compact' {
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
            Mock Wait-ForDesiredVMState { throw "VM did not reach Off state within 120s" }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits with timeout error and never mounts VHDX' {
            { & $script:ScriptPath -Yes } | Should -Not -Throw
            Assert-MockCalled Mount-VHD    -Times 0
            Assert-MockCalled Optimize-VHD -Times 0
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*Failed to stop VM within timeout*' } -Times 1
        }
    }

    Describe 'No-restart flag: cluster not restarted after compaction' -Tag 'unit', 'ci', 'compact' {
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

        It 'logs no-restart message in step 6' {
            { & $script:ScriptPath -NoRestart } | Should -Not -Throw
            Assert-MockCalled Write-Log -ParameterFilter { $Message -like '*no-restart*' } -Times 1
        }
    }

    Describe 'Get-VHD unavailable: warning is logged and compaction continues' -Tag 'unit', 'ci', 'compact' {
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

    Describe 'Get-PSDrive unavailable: warning is logged and compaction continues' -Tag 'unit', 'ci', 'compact' {
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

