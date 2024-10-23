# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
Import-Module $logModule, $configModule

function Get-K2sHosts() {
    $clusterServicesCidr = Get-ConfiguredClusterCIDRServices
    $clusterCidr = Get-ConfiguredClusterCIDR
    $ipControlPlaneCidr = Get-ConfiguredControlPlaneCIDR

    return @($clusterServicesCidr, $clusterCidr, $ipControlPlaneCidr, "local", "svc.cluster.local")
}

<#
.SYNOPSIS
Gets whether proxy settings are configured for the user in Windows.

.DESCRIPTION
When Proxy settings are configured for the User in Windows, the enabled status is checked in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable

If ProxyEnable is set to 1, the proxy settings are enabled. In this case, the function returns true.
If ProxyEnable is set to 0, the proxy settings are enabled. In this case, the function returns false.
#>
function Get-ProxyEnabledStatusFromWindowsSettings {
    try {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        
        if ($reg.ProxyEnable -eq '1') {
            return $true
        }
        else {
            return $false
        }
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
Gets the configured proxy server for the user in Windows. Should be called only when Proxy is enabled. 

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy server is configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyServer
#>
function Get-ProxyServerFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    $proxyServer = $reg.ProxyServer
    if ($null -ne $proxyServer -and !($proxyServer | Select-String -Pattern 'http://')) {
        $proxyServer = 'http://' + $proxyServer
    }

    return $proxyServer
}

<#
.SYNOPSIS
Gets the configured proxy overrides for the user in windows. Proxy overrides are the hosts for which the requests must not
be forwarded to the proxy. Should be called only when Proxy is enabled.

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy overrides are configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverrides
#>
function Get-ProxyOverrideFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    return $reg.ProxyOverride
}

<#
.SYNOPSIS
Identifies the proxy server to be used. 
If $Proxy is specified, then no identification is done.     
If $Proxy is not specified, then the proxy settings are fetched from registry. Based on the registry keys, the appropriate proxy server
to be used is returned.
#>
function Get-OrUpdateProxyServer ([string]$Proxy) {
    if ($Proxy -eq '') {
        Write-Log 'Determining if proxy is configured by the user in Windows Proxy settings.' -Console
        $proxyEnabledStatus = Get-ProxyEnabledStatusFromWindowsSettings
        if ($proxyEnabledStatus) {
            $Proxy = Get-ProxyServerFromWindowsSettings
            Write-Log "Configured proxy server in Windows Proxy settings: $Proxy" -Console
        }
        else {
            Write-Log 'No proxy configured in Windows Proxy Settings.' -Console
        }
    }
    return $Proxy
}

function Add-K2sHostsToNoProxyEnvVar() {
    $noProxyEnvVar = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
    $k2sHosts = Get-K2sHosts

    if (![string]::IsNullOrWhiteSpace($noProxyEnvVar)) {
        $noProxyList = $noProxyEnvVar -split ","
    } else {
        $noProxyList = @()
    }

    $noProxyList += $k2sHosts
    $noProxyList = $noProxyList | Sort-Object -Unique
    $updatedNoProxyEnvVar = $noProxyList -join ","
    [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Process")
    [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Machine")
}

function Remove-K2sHostsFromNoProxyEnvVar() {
    $noProxyEnvVar = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
    $k2sHosts = Get-K2sHosts

    if (![string]::IsNullOrWhiteSpace($noProxyEnvVar)) {
        $noProxyList = $noProxyEnvVar -split ","
        $noProxyList = $noProxyList | Where-Object { $_ -notin $k2sHosts }
        $updatedNoProxyEnvVar = $noProxyList -join ","
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Process")
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Machine")
    }
}

Export-ModuleMember -Function Get-OrUpdateProxyServer, Add-K2sHostsToNoProxyEnvVar, Remove-K2sHostsFromNoProxyEnvVar