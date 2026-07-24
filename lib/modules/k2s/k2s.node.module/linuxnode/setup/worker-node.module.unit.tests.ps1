# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $script:modulePath = "$PSScriptRoot/worker-node.module.psm1"
    $script:moduleName = (Import-Module $script:modulePath -PassThru -Force -DisableNameChecking).Name
}

# The functions under test call commands defined in imported sub-modules
# (e.g. common-setup.module) that are not directly resolvable inside
# InModuleScope at test time. Each test injects lightweight function stubs
# into the module scope right before mocking them, so Pester's Mock can find
# and override the command. The stubs are never executed with real behavior -
# every one is replaced by a Mock in the same scope.

Describe 'Add-LinuxWorkerNode failure cleanup' -Tag 'unit', 'ci', 'worker-node' {
    Context 'When a step after Add-NodeConfig fails' {
        It 'preserves the node config entry (for upgrade/restore) and re-throws the original error' {
            InModuleScope $moduleName {
                function Add-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Set-UpComputerBeforeProvisioning { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Repair-LinuxWorkerNodeRegistriesConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Clear-LinuxWorkerNodeRoutes { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Join-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-CmdOnVmViaSSHKey { param([Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: Add-NodeConfig succeeds, first provisioning step throws.
                Mock Write-Log {}
                Mock Add-NodeConfig {}
                Mock Set-UpComputerBeforeProvisioning { throw 'join failed' }
                Mock Remove-NodeConfig {}
                Mock Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer {}
                Mock Join-LinuxNode {}
                Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = '' } }

                # Act + Assert: original error is preserved (AC1)
                { Add-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100' -WindowsHostIpAddress '172.19.1.1' -installedDistributionOnRemoteComputer 'debian' } |
                    Should -Throw '*join failed*'

                # Assert: config entry is NOT deleted - it must survive for a system
                # upgrade to restore the node; 'k2s node remove' cleans it up later (AC1)
                Should -Invoke Remove-NodeConfig -Times 0 -Exactly
            }
        }
    }
}

Describe 'Remove-LinuxWorkerNode robustness' -Tag 'unit', 'ci', 'worker-node' {
    Context 'When the node is not part of the cluster (orphaned entry)' {
        It 'still removes the node config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node absent from kubectl, remote cleanup would fail.
                Mock Write-Log {}
                Mock Get-NodeConfig { $null }
                Mock Invoke-Kubectl { [pscustomobject]@{ Output = 'controlplane   Ready   control-plane' } }
                Mock Remove-LinuxNode { throw 'should not be called for absent node' }
                Mock Remove-KubernetesArtifacts { throw 'node unreachable' }
                Mock Remove-NodeConfig {}

                # Act
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100'

                # Assert: config entry removed despite cluster/remote failures (AC3)
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }
                Should -Invoke Remove-LinuxNode -Times 0 -Exactly
            }
        }
    }

    Context 'When the node is part of the cluster (normal removal)' {
        It 'removes it from the cluster and clears the config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node present in kubectl.
                Mock Write-Log {}
                Mock Get-NodeConfig { $null }
                Mock Invoke-Kubectl { [pscustomobject]@{ Output = "controlplane   Ready`nscaleoutbox   Ready   worker" } }
                Mock Remove-LinuxNode {}
                Mock Remove-KubernetesArtifacts {}
                Mock Remove-NodeConfig {}

                # Act
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100'

                # Assert: normal path unchanged (AC4)
                Should -Invoke Remove-LinuxNode -Times 1 -Exactly
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly
            }
        }
    }

    Context 'When the VM link is broken (-SkipRemoteCleanup)' {
        It 'skips all remote/cluster steps but still clears the config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-PersistentLinuxWorkerNodeRoutes { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node is a HOST node but unreachable; any remote call would fail.
                Mock Write-Log {}
                Mock Get-NodeConfig { [pscustomobject]@{ NodeType = 'HOST' } }
                Mock Invoke-Kubectl { throw 'kubectl unreachable' }
                Mock Remove-LinuxNode { throw 'should not be called' }
                Mock Remove-KubernetesArtifacts { throw 'should not be called' }
                Mock Remove-PersistentLinuxWorkerNodeRoutes { throw 'should not be called' }
                Mock Remove-NodeConfig {}

                # Act: caller knows the VM link is broken (matches PR #2781 Remove.ps1)
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100' -SkipRemoteCleanup

                # Assert: no remote/cluster work attempted, but config entry cleared (AC3)
                Should -Invoke Invoke-Kubectl -Times 0 -Exactly
                Should -Invoke Remove-LinuxNode -Times 0 -Exactly
                Should -Invoke Remove-KubernetesArtifacts -Times 0 -Exactly
                Should -Invoke Remove-PersistentLinuxWorkerNodeRoutes -Times 0 -Exactly
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }
            }
        }
    }
}
