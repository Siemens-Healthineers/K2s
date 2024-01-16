# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

function Write-OutputIntoDumpFile {
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'Output of the command being executed', ValueFromPipeline = $true)]
        [string[]]$Messages,

        [Parameter(Mandatory = $true, HelpMessage = 'File in which the message should be dumped')]
        [ValidateNotNullOrEmpty()]
        [string]$DumpFilePath,

        [Parameter(Mandatory = $true, HelpMessage = 'Description of the command being executed')]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [Parameter(Mandatory = $false, HelpMessage = 'Helps to distinguish the output of the previous execution with the current execution')]
        [string]$Separator = ' '
    )

    Begin {
        if (-not (Test-Path $DumpFilePath)) {
            New-DumpFile -FilePath $DumpFilePath
        } else {
            $Separator | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
        }

        $Description | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
    }

    Process {
        $Messages | Out-File -Append -FilePath $DumpFilePath -Encoding UTF8
    }
}

function New-DumpFile(
    [string] $FilePath
) {


    #Check If directory is present. If not create it.
    $directoryPath = [System.IO.Path]::GetDirectoryName($FilePath)
    
    if (-not (Test-Path $directoryPath)) {
        New-Item -Path $directoryPath -ItemType Directory -Force | Out-Null
    }
    #Finally create the file
    New-Item -Path $FilePath -ItemType File -Force | Out-Null
}

Export-ModuleMember -Function Write-OutputIntoDumpFile