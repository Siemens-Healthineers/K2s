# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $vmModule, $pathModule

$setupJsonFile = Get-SetupConfigFilePath
$kubePath = Get-KubePath
$binDir = "$kubePath\bin"
$nerdctlExe = "$binDir\nerdctl.exe"
$dockerDir = "$binDir\docker"
$dockerExe = "$dockerDir\docker.exe"

function Add-RegistryToSetupJson([string]$Name) {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json

    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if (!$registryMemberExists) {
        $parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{Registries = @() } -PassThru
    }

    $registryAlreadyExists = $parsedSetupJson.Registries | Where-Object { $_ -eq $Name }
    if (!$registryAlreadyExists) {
        $parsedSetupJson.Registries += $Name
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $setupJsonFile -Confirm:$false
    }
}

function Remove-RegistryFromSetupJson([string]$Name, [bool]$IsRegex) {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json

    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if ($registryMemberExists) {
        $registries = $parsedSetupJson.Registries
        if ($IsRegex) {
            $newRegistry = @($registries | Where-Object { $_ -notmatch $Name })
        }
        else {
            $newRegistry = @($registries | Where-Object { $_ -ne $Name })
        }

        if ($newRegistry) {
            $parsedSetupJson.Registries = $newRegistry
        }
        else {
            $parsedSetupJson.PSObject.Properties.Remove('Registries')
        }
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $setupJsonFile -Confirm:$false
    }
}

function Get-RegistriesFromSetupJson() {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json
    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if ($registryMemberExists) {
        $registries = $parsedSetupJson.Registries
        return $registries
    }
    return $null
}

function Add-RegistryToContainerdConf {
    param(
        [Parameter()]
        [String]
        $registryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$kubePath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $content = Get-Content $containerdConfig | Out-String
    if ($content.Contains("[plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth]")) {
        return
    }

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_registry_auth' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth]`r`n          auth = ""$auth""`r`n`r`n        #add_new_registry_auth") } | Set-Content $containerdConfig
    }

    $tlsPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_insecure_verify_skip' | Select-Object -ExpandProperty Line
    if ( $tlsPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($tlsPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".tls]`r`n          insecure_skip_verify = true`r`n`r`n        #add_new_insecure_verify_skip") } | Set-Content $containerdConfig
    }
}


function Connect-Docker {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            $success = $(&$dockerExe login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        } else {
            $success = $(&$dockerExe login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }

        if ($success) {
            Write-Log 'docker login succeeded'
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Connect-Nerdctl {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            $success = $(&$nerdctlExe login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        } else {
            $success = $(&$nerdctlExe login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }

        if ($success) {
            Write-Log 'nerdctl login succeeded'
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Connect-Buildah {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah login --authfile /root/.config/containers/auth.json '$registry' > /dev/null 2>&1" -NoLog
        } else {
            Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah login --authfile /root/.config/containers/auth.json -u '$username' -p '$password' '$registry' > /dev/null 2>&1" -NoLog
        }

        if ($?) {
            Write-Log 'buildah login succeeded'
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Get-ConfiguredRegistryFromImageName {
    param (
        [Parameter()]
        [string] $ImageName
    )

    if (!$ImageName.Contains('/')) {
        throw 'Please check ImageName! Cannot get registry name!'
    }

    $registry = $($ImageName -split '/')[0]

    $registries = Get-RegistriesFromSetupJson
    if ($null -eq $registries) {
        return $null
    }
    $registryExists = $registries | Where-Object { $_ -eq $registry }

    if ($registryExists) {
        return $registry
    } else {
        return $null
    }
}

Export-ModuleMember -Function Add-RegistryToSetupJson,
                              Remove-RegistryFromSetupJson,
                              Get-RegistriesFromSetupJson,
                              Add-RegistryToContainerdConf,
                              Connect-Docker,
                              Connect-Buildah,
                              Connect-Nerdctl,
                              Get-ConfiguredRegistryFromImageName