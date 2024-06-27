# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule

$configFilePath = "C:\etc\k2s\proxy.conf"

class ProxyConf {
    [string]$HttpProxy
    [string]$HttpsProxy
    [string]$NoProxy
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
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        
    if ($reg.ProxyEnable -eq '1') {
        return $true
    }
    else {
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

    $proxyServer = 'http://' + $reg.ProxyServer
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
    $proxyOverrides = $reg.ProxyOverride -replace ";", ","
    return $proxyOverrides
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

function New-ProxyConfig {
    param(
        [string] $Proxy,
        [string[]] $NoProxy
    )

    # If $Proxy and $NoProxy are empty, get values from the Windows registry
    if ($Proxy -eq '' -and $NoProxy.Count -gt 0) {
        Write-Log 'Determining if proxy is configured by the user in Windows Proxy settings.' -Console
        $proxyEnabledStatus = Get-ProxyEnabledStatusFromWindowsSettings
        if ($proxyEnabledStatus) {
            $Proxy = Get-ProxyServerFromWindowsSettings
            $NoProxy = Get-ProxyOverrideFromWindowsSettings
            Write-Log "Configured proxy server in Windows Proxy settings: Proxy: $Proxy, ProxyOverrides: $NoProxy" -Console
        }
        else {
            Write-Log 'No proxy configured in Windows Proxy Settings.' -Console
        }
    }

    # Ensure the directory exists
    $configFileDirectory = Split-Path -Path $configFilePath -Parent
    if (!(Test-Path -Path $configFileDirectory)) {
        New-Item -ItemType Directory -Path $configFileDirectory | Out-Null
    }

    # Create or overwrite the config file
    New-Item -ItemType File -Path $configFilePath -Force | Out-Null

    # Write the proxy settings to the config file
    $NoProxyString = $NoProxy -join ','
    Add-Content -Path $configFilePath -Value "http_proxy=$Proxy"
    Add-Content -Path $configFilePath -Value "https_proxy=$Proxy"
    Add-Content -Path $configFilePath -Value "no_proxy=$NoProxyString"
}

function Get-ProxyConfig {
    $httpProxy = ""
    $httpsProxy = ""
    $noProxy = ""

    # Check if the config file exists
    if (!(Test-Path -Path $configFilePath)) {
        throw "Config file not found at path: $configFilePath"
    }
    
    Get-Content "$configFilePath" | ForEach-Object {
        $line = $_
        switch -regex ($line) {
            "http_proxy=" { $httpProxy = (($_ -replace "http_proxy=", "") -replace '"', '') -replace "'",""}
            "https_proxy=" { $httpsProxy = (($_ -replace "https_proxy=", "") -replace '"', '') -replace "'",""}
            "no_proxy=" { $noProxy = (($_ -replace "no_proxy=", "") -replace '"', '') -replace "'",""}
        }
    }

    return [ProxyConf]@{
        HttpProxy = $httpProxy; 
        Httpsproxy = $httpsProxy; 
        NoProxy = $noProxy
    }
}

Export-ModuleMember -Function Get-OrUpdateProxyServer, Get-ProxySettings, New-ProxyConfig, Get-ProxyConfig