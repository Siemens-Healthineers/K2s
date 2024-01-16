# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$pathModule = "$PSScriptRoot\..\path\path.module.psm1"

Import-Module $pathModule

function Test-LastExecutionForSuccess {
    return $LASTEXITCODE -eq 0
}

function Get-FromYamlFile {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Path = $(throw 'Path not specified')
    )
    if ((Test-Path -Path $Path) -ne $true) {
        throw "path '$Path' does not exist"
    }

    $kubeBinPath = Get-KubeBinPath
    $yaml2jsonExe = [System.IO.Path]::Combine($kubeBinPath, 'yaml2json.exe')
    $tempJsonFile = New-TemporaryFile
    $errorLoglevel = 8

    try {
        Invoke-Expression "&`"$yaml2jsonExe`" -input `"$Path`" -output `"$tempJsonFile`" -loglevel `"$errorLoglevel`""
        if ((Test-LastExecutionForSuccess) -ne $true) {
            throw "yaml2json conversion failed for '$Path'. See log output above for details."
        }
    
        $result = Get-Content -Path $tempJsonFile | Out-String | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $tempJsonFile -Force -ErrorAction Continue
    }

    return $result
}

Export-ModuleMember -Function Get-FromYamlFile