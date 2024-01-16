# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Proxy = ''
)

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\GlobalFunctions.ps1

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

$ErrorActionPreference = 'Stop'

$urlRoot = 'https://cloud.debian.org/images/cloud/bullseye/latest'

$urlFile = 'debian-11-genericcloud-amd64.qcow2'

$url = "$urlRoot/$urlFile"

if (-not $OutputPath) {
    $OutputPath = Get-Item '.\'
}

$imgFile = Join-Path $OutputPath $urlFile

if ([System.IO.File]::Exists($imgFile)) {
    # use Write-Host to not add the entries to the returned stream !
    # don't use here write-output, because that adds the output to returned value
    Write-Log "File '$imgFile' already exists. Nothing to do."
}
else {
    DownloadFile $imgFile $url $false $Proxy

    Write-Log "Checking file integrity..."
    $allHashs = ""

    if ( $Proxy -ne '') {
        Write-Log "Using Proxy $Proxy to download SHA sum from $urlRoot"
        $allHashs = curl.exe --retry 3 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --proxy $Proxy --ssl-no-revoke -k
    }
    else {
        $allHashs = curl.exe --retry 3 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --ssl-no-revoke --noproxy '*'
    }

    $sha1Hash = Get-FileHash $imgFile -Algorithm SHA512
    $m = [regex]::Matches($allHashs, "(?<Hash>\w{128})\s\s$urlFile")
    if (-not $m[0]) { throw "Cannot get hash for $urlFile." }
    $expectedHash = $m[0].Groups['Hash'].Value
    if ($sha1Hash.Hash -ne $expectedHash) { throw "Integrity check for '$imgFile' failed." }
    Write-Log "  ...done"
}

return $imgFile
