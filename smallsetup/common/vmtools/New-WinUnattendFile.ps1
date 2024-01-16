# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminPwd,

    [Parameter(Mandatory=$true)]
    [string]$WinVersionKey,

    [string]$VMName,

    [string]$FilePath,

    [string]$Locale
)

$ErrorActionPreference = 'Stop'

$winTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" processorArchitecture="amd64" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey></ProductKey>
            <ComputerName></ComputerName>
        </component>
        <component name="Microsoft-Windows-International-Core" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale></InputLocale>
            <SystemLocale></SystemLocale>
            <UserLocale></UserLocale>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-SQMApi" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-Deployment" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>net user administrator /active:yes</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>    
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value></Value>
                    <PlainText>false</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
</unattend>
'@

$winXmlFile = [xml]$winTemplate

if (-not $FilePath) {
    $FilePath = Join-Path $env:TEMP 'unattend.xml'
}

if ($VMName) {
    $winXmlFile.unattend.settings[0].component[0].ComputerName = $VMName
}

$encodedPassword = [System.Text.Encoding]::Unicode.GetBytes($AdminPwd + 'AdministratorPassword')
$winXmlFile.unattend.settings[1].component.UserAccounts.AdministratorPassword.Value = [Convert]::ToBase64String($encodedPassword)

$winXmlFile.unattend.settings[0].component[0].ProductKey = $WinVersionKey

if ($Locale) {
    $winXmlFile.unattend.settings[0].component[1].InputLocale = $Locale
    $winXmlFile.unattend.settings[0].component[1].SystemLocale = $Locale
    $winXmlFile.unattend.settings[0].component[1].UserLocale = $Locale
}

$xmlTextWriter = New-Object System.XMl.XmlTextWriter($FilePath, [System.Text.Encoding]::UTF8)
$xmlTextWriter.Formatting = [System.Xml.Formatting]::Indented
$winXmlFile.Save($xmlTextWriter)
$xmlTextWriter.Dispose()

$FilePath
