# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule

$proxyConfigFp = "C:\ProgramData\k2s\proxy.conf"

class ProxyConfig {
    [string] $HttpProxy
    [string] $HttpsProxy
    [string[]] $NoProxy
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

    return $false
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
    if (!($proxyServer | Select-String -Pattern 'http://')) {
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

<#
.SYNOPSIS
Creates the k2s proxy configuration file at C:\ProgramData\k2s\proxy.conf. 
This method must be invoked during the installation of k2s. 

.DESCRIPTION
When this function is called during the installation of k2s, it identifies the relevant proxy configuration and writes them into the configuration file.
If the function parameters are specified, then they have precedence over proxy settings in windows.
#>
function New-ProxyConfig {
    param(
        [string] $Proxy,
        [string[]] $NoProxy
    )

    # If $Proxy and $NoProxy are empty, get values from the Windows registry
    if ([string]::IsNullOrWhiteSpace($Proxy)) {
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
    $configFileDirectory = Split-Path -Path $proxyConfigFp -Parent
    if (!(Test-Path -Path $configFileDirectory)) {
        New-Item -ItemType Directory -Path $configFileDirectory | Out-Null
    }

    # Create or overwrite the config file
    New-Item -ItemType File -Path $proxyConfigFp -Force | Out-Null

    # Write the proxy settings to the config file
    $NoProxyString = $NoProxy -join ','
    Add-Content -Path $proxyConfigFp -Value "http_proxy=$Proxy"
    Add-Content -Path $proxyConfigFp -Value "https_proxy=$Proxy"
    Add-Content -Path $proxyConfigFp -Value "no_proxy=$NoProxyString"
}

<#
.SYNOPSIS
Gets the proxy configuration object.

.DESCRIPTION
When the function is invoked, the proxy configuration object is created by reading the proxy configuration file located at 
C:\ProgramData\k2s\proxy.conf

If the proxy configuration file is not found, then an error is thrown. Hence, this method must be invoked after New-ProxyConfig is invoked.
#>
function Get-ProxyConfig {
    $httpProxy = ""
    $httpsProxy = ""
    $noProxy = ""

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    Get-Content "$proxyConfigFp" | ForEach-Object {
        $line = $_
        switch -regex ($line) {
            "http_proxy=" { $httpProxy = (($_ -replace "http_proxy=", "") -replace '"', '') -replace "'",""}
            "https_proxy=" { $httpsProxy = (($_ -replace "https_proxy=", "") -replace '"', '') -replace "'",""}
            "no_proxy=" { $noProxy = (($_ -replace "no_proxy=", "") -replace '"', '') -replace "'",""}
        }
    }

    $noProxyList = if ($noProxy -eq "") { @() } else { $noProxy -split ',' }

    return [ProxyConfig]@{
        HttpProxy = $httpProxy; 
        Httpsproxy = $httpsProxy; 
        NoProxy = [string[]]$noProxyList
    }
}

<#
.SYNOPSIS
Sets the proxy server configuration.

.DESCRIPTION
This function allows you to set the proxy server configuration by providing the HTTP and HTTPS proxy server addresses.
If the configuration file does not exist at the specified path, an error will be thrown.

.PARAMETER roxy
The HTTP proxy server address to be set.

.EXAMPLE
Set-ProxyServer -Proxy "http://proxy.example.com:8080"
Sets the HTTP and HTTPS proxy server addresses to "http://proxy.example.com:8080".
#>
function Set-ProxyServer {
    param (
        [string]$Proxy
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Update the proxy settings
    if ($Proxy) {
        $proxyConfig.HttpProxy = $Proxy
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy='$($proxyConfig.HttpProxy)'"
        "https_proxy='$($proxyConfig.HttpsProxy)'"
        "no_proxy='$($proxyConfig.NoProxy)'"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Adds entries to the NoProxy array in the proxy configuration file.

.DESCRIPTION
The Add-NoProxyEntry function reads the existing proxy configuration, adds the specified entries to the NoProxy array if they do not already exist, and writes the updated configuration back to the proxy configuration file.

.PARAMETER Entries
The entries to add to the NoProxy array.

.EXAMPLE
Add-NoProxyEntry -Entries "example.com"
Adds "example.com" to the NoProxy array in the proxy configuration file.

.EXAMPLE
Add-NoProxyEntry -Entries "example.com", "anotherdomain.com"
Adds "example.com" and "anotherdomain.com" to the NoProxy array in the proxy configuration file.
#>
function Add-NoProxyEntry {
    param (
        [string[]]$Entries
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Add new entries to the NoProxy array
    foreach ($entry in $Entries) {
        if (-not ($proxyConfig.NoProxy -contains $entry)) {
            $proxyConfig.NoProxy += $entry
        }
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy=$($proxyConfig.HttpProxy)"
        "https_proxy=$($proxyConfig.HttpsProxy)"
        "no_proxy=$($proxyConfig.NoProxy -join ",")"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Removes entries from the NoProxy array in the proxy configuration file.

.DESCRIPTION
The Remove-NoProxyEntry function reads the existing proxy configuration, removes the specified entries from the NoProxy array, and writes the updated configuration back to the proxy configuration file.

.PARAMETER Entries
The entries to remove from the NoProxy array.

.EXAMPLE
Remove-NoProxyEntry -Entries "example.com"
Removes "example.com" from the NoProxy array in the proxy configuration file.

.EXAMPLE
Remove-NoProxyEntry -Entries "example.com", "anotherdomain.com"
Removes "example.com" and "anotherdomain.com" from the NoProxy array in the proxy configuration file.

#>
function Remove-NoProxyEntry {
    param (
        [string[]]$Entries
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Remove entries from the NoProxy array
    foreach ($entry in $Entries) {
        $proxyConfig.NoProxy = $proxyConfig.NoProxy | Where-Object { $_ -ne $entry }
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy=$($proxyConfig.HttpProxy)"
        "https_proxy=$($proxyConfig.HttpsProxy)"
        "no_proxy=$($proxyConfig.NoProxy -join ",")"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Reset the proxy configuration by setting all entries to empty.

.DESCRIPTION
The Reset-ProxyConfig function sets the HttpProxy, HttpsProxy, and NoProxy entries in the proxy configuration file to empty values. This effectively resets the proxy configuration to a default state with no proxy settings.

.NOTES
The function checks if the proxy configuration file exists before attempting to reset the configuration.
The proxy configuration file path is hardcoded as C:\ProgramData\k2s\proxy.conf.

.EXAMPLE
Reset-ProxyConfig
Resets the proxy configuration by setting all entries to empty.
#>
function Reset-ProxyConfig {
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    $newContent = @(
        "http_proxy="
        "https_proxy="
        "no_proxy="
    )

    $newContent | Set-Content -Path $proxyConfigFp
}

Export-ModuleMember -Function Get-OrUpdateProxyServer,
                              New-ProxyConfig, 
                              Get-ProxyConfig,
                              Set-ProxyServer, 
                              Add-NoProxyEntry, 
                              Remove-NoProxyEntry, 
                              Reset-ProxyConfig