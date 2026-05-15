# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\downloader.module.psm1"
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Invoke-PackageWindowsImageDownload' -Tag 'unit', 'ci', 'package' {
    BeforeEach {
        $script:operations = @()

        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-Service { return $null } -ParameterFilter { $Name -eq 'httpproxy' }
        Mock -ModuleName $moduleName Install-WinHttpProxy { $script:operations += 'install-httpproxy' }
        Mock -ModuleName $moduleName Start-WinHttpProxy { $script:operations += 'start-httpproxy' }
        Mock -ModuleName $moduleName Remove-WinHttpProxy { $script:operations += 'remove-httpproxy' }
        Mock -ModuleName $moduleName Install-WinContainerd { $script:operations += 'install-containerd' }
        Mock -ModuleName $moduleName Invoke-DownloadWindowsImages { $script:operations += 'download-images' }
        Mock -ModuleName $moduleName Uninstall-WinContainerd { $script:operations += 'uninstall-containerd' }
    }

    It 'installs and removes temporary httpproxy when proxy is configured and no service exists' {
        InModuleScope $moduleName {
            Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy 'http://proxy.example.com:8080' -WindowsNodeArtifactsDirectory 'C:\windowsnode'
        }

        Should -Invoke Install-WinHttpProxy -ModuleName $moduleName -Exactly 1 -ParameterFilter { $Proxy -eq 'http://proxy.example.com:8080' }
        Should -Invoke Remove-WinHttpProxy -ModuleName $moduleName -Exactly 1
        $script:operations | Should -Be @('install-httpproxy', 'install-containerd', 'download-images', 'uninstall-containerd', 'remove-httpproxy')
    }

    It 'starts and preserves existing httpproxy when proxy is configured and service exists' {
        Mock -ModuleName $moduleName Get-Service { return [PSCustomObject]@{ Name = 'httpproxy'; Status = 'Stopped' } } -ParameterFilter { $Name -eq 'httpproxy' }

        InModuleScope $moduleName {
            Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy 'http://proxy.example.com:8080' -WindowsNodeArtifactsDirectory 'C:\windowsnode'
        }

        Should -Invoke Install-WinHttpProxy -ModuleName $moduleName -Exactly 0
        Should -Invoke Start-WinHttpProxy -ModuleName $moduleName -Exactly 1 -ParameterFilter { $OnlyProxy -eq $true }
        Should -Invoke Remove-WinHttpProxy -ModuleName $moduleName -Exactly 0
        $script:operations | Should -Be @('start-httpproxy', 'install-containerd', 'download-images', 'uninstall-containerd')
    }

    It 'does not manage httpproxy when no proxy is configured' {
        InModuleScope $moduleName {
            Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy '' -WindowsNodeArtifactsDirectory 'C:\windowsnode'
        }

        Should -Invoke Get-Service -ModuleName $moduleName -Exactly 0
        Should -Invoke Install-WinHttpProxy -ModuleName $moduleName -Exactly 0
        Should -Invoke Start-WinHttpProxy -ModuleName $moduleName -Exactly 0
        Should -Invoke Remove-WinHttpProxy -ModuleName $moduleName -Exactly 0
        $script:operations | Should -Be @('install-containerd', 'download-images', 'uninstall-containerd')
    }

    It 'cleans up containerd and temporary httpproxy when image download fails' {
        Mock -ModuleName $moduleName Invoke-DownloadWindowsImages {
            $script:operations += 'download-images'
            throw 'image pull failed'
        }

        InModuleScope $moduleName {
            { Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy 'http://proxy.example.com:8080' -WindowsNodeArtifactsDirectory 'C:\windowsnode' } | Should -Throw '*image pull failed*'
        }

        Should -Invoke Uninstall-WinContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter { $ShallowUninstallation -eq $true }
        Should -Invoke Remove-WinHttpProxy -ModuleName $moduleName -Exactly 1
        $script:operations | Should -Be @('install-httpproxy', 'install-containerd', 'download-images', 'uninstall-containerd', 'remove-httpproxy')
    }
}
