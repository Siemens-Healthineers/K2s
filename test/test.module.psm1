# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

function Invoke-CommandWithPowershell([string]$Command) {
    $powershellExe = 'powershell.exe'
    $arguments = "-noprofile -Command `"$Command`""
    Write-Host "Calling $powershellExe $arguments"
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellExe
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.UseShellExecute = $false
        $startInfo.Arguments = $arguments
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        # Register Object Events for stdin\stdout reading
        $OutEvent = Register-ObjectEvent -Action {
            Write-Host $Event.SourceEventArgs.Data
        } -InputObject $process -EventName OutputDataReceived
        $ErrEvent = Register-ObjectEvent -Action {
            Write-Host $Event.SourceEventArgs.Data
        } -InputObject $process -EventName ErrorDataReceived
        $process.Start() | Out-Null
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $process.WaitForExit()
        # Unregister events
        $OutEvent.Name, $ErrEvent.Name |
        ForEach-Object { Unregister-Event -SourceIdentifier $_ }
        $exitCode = $process.ExitCode
        return $exitCode
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-GoCommand {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $Cmd
    )
    $currentHttpProxy = $env:http_proxy
    $currentHttpsProxy = $env:https_proxy

    try {
        $env:http_proxy = $Proxy
        $env:https_proxy = $Proxy
        $exitCode = Invoke-CommandWithPowershell -Command $Cmd
        if ($exitCode -ne 0) {
            $errorMessage = "Command $Cmd resulted in a non-zero exit code. Exit Code: $exitCode"
            throw $errorMessage
        }
    }
    finally {
        $env:http_proxy = $currentHttpProxy
        $env:https_proxy = $currentHttpsProxy
    }
}

function New-GinkgoTestCmd {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false
    )
    $ginkgoCmd = 'ginkgo'
    if ($V -eq $true) {
        $ginkgoCmd += ' -v'
    }

    $ginkgoCmd += ' --require-suite' # complains about specs without test suite
    $ginkgoCmd += " --junit-report=GoTest-$((Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString()).xml"
    $ginkgoCmd += " --output-dir=$OutDir"

    if ($null -eq $Tags -and $null -eq $ExcludeTags) {
        return $ginkgoCmd
    }

    # see https://onsi.github.io/ginkgo/#filtering-specs
    $ginkgoCmd += ' --label-filter="'
    $isFirstLabel = $true

    for ($i = 0; $i -lt $tags.Length; $i++) {
        if ($i -eq 0) {
            $isFirstLabel = $false

            $ginkgoCmd += '( '
        }
        else {
            $ginkgoCmd += ' || '
        }

        $ginkgoCmd += $tags[$i]

        if ($i -eq $tags.Length - 1) {
            $ginkgoCmd += ' )'
        }
    }

    foreach ($tag in $ExcludeTags) {
        if ($isFirstLabel -eq $true) {
            $isFirstLabel = $false
        }
        else {
            $ginkgoCmd += ' && '
        }

        $ginkgoCmd += "!$tag"
    }

    $ginkgoCmd += '" {path}'

    return $ginkgoCmd
}

function Install-GinkgoIfNecessary {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $GinkgoVersion = $(throw 'GinkgoVersion not specified')
    )
    $ginkgoCmd = Get-Command -ErrorAction Ignore -Type Application ginkgo

    if (!$ginkgoCmd) {
        Write-Output 'Ginkgo not found, installing it..'
        Invoke-GoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$GinkgoVersion'"
    }

    $foundVersion = (ginkgo.exe version).Split(' ')[2].Trim()

    Write-Output "Found Ginkgo version $foundVersion"

    if ($foundVersion -ne $GinkgoVersion) {
        Write-Output "Updating Ginkgo to version $GinkgoVersion.."
        Invoke-GoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$GinkgoVersion'"
    }
}

function Install-PesterIfNecessary {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $PesterVersion = $(throw 'PesterVersion not specified')
    )
    $pesterModule = Get-InstalledModule -Name Pester

    if (!$pesterModule) {
        Write-Output 'Pester not found, installing it..'

        $pkgProviderVersion = '2.8.5.201 '

        if ($Proxy -ne '') {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force -Proxy $Proxy
            Register-PSRepository -Default -Proxy $Proxy -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Proxy $Proxy -Force -SkipPublisherCheck -MinimumVersion $PesterVersion
        }
        else {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force
            Register-PSRepository -Default -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion $PesterVersion
        }
        return
    }
    
    $foundVersion = "$($pesterModule.Version.Major).$($pesterModule.Version.Minor).$($pesterModule.Version.Build)"
    
    Write-Output "Found Pester version $foundVersion"
    
    if ($foundVersion -ne $PesterVersion) {
        Write-Output "Updating Pester to version $PesterVersion.."

        Update-Module -Name Pester -RequiredVersion $PesterVersion -Force
    }
}

function Start-GinkgoTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false,
        [Parameter(Mandatory = $false)]
        [switch]
        $VV = $false
    )
    Write-Output "  Executing Go-based tests in '$WorkingDir' with verbose='$V' and super-verbose='$VV' for tags '$Tags' and excluding tags '$ExcludeTags'.."

    if ($Proxy -ne '') {
        Write-Output "  Using Proxy to download go modules: '$Proxy'.."
        Invoke-GoCommand -Proxy $Proxy -Cmd "cd $WorkingDir;ls;go.exe mod download"
    }

    $ginkgoCmd = $(New-GinkgoTestCmd -Tags $Tags -ExcludeTags $ExcludeTags -OutDir $OutDir -V:$V)
    $testFolders = (Get-ChildItem -Path $WorkingDir -File -Recurse -Filter '*_test.go').DirectoryName | Get-Unique

    if ($VV -eq $true) {
        Write-Output '  Found tests in folders:'
        $testFolders | ForEach-Object { Write-Output "       $_" }  
    }  

    foreach ($folder in $testFolders) {
        # TODO: refactor
        $labelsResult = (ginkgo labels $folder *>&1) | Out-String

        if ($labelsResult -match 'Found no test suites') {
            Write-Output "No test suites found in '$folder'"
            continue
        }

        $foundLabels = [System.Collections.ArrayList]@()
        $packageName = $labelsResult.Split(':')[0]
        
        if ($labelsResult -match 'No labels found') {
            if ($VV -eq $true) {
                Write-Output "  No labels found for package '$packageName'"            
            }
        }
        else {
            $result = $labelsResult.Trim().Replace(' ', '').Split(':')[1] | ConvertFrom-Json

            $foundLabels.AddRange($result) | Out-Null
        }

        if ($VV -eq $true) {
            Write-Output "  Found labels for package '$packageName': $foundLabels"             
        }  

        $isMatch = (($null -eq $ExcludeTags) -or ($null -eq ($ExcludeTags | Where-Object { $foundLabels -contains $_ }))) -and (($null -eq $Tags) -or ($null -ne ($Tags | Where-Object { $foundLabels -contains $_ })))
        if ($isMatch -ne $true) {
            if ($VV -eq $true) {
                Write-Output "  No match for package '$packageName'"            
            }
            continue
        }

        if ($VV -eq $true) {
            Write-Output "  Match for package '$packageName'"             
        } 

        $cmd = $ginkgoCmd -replace '{path}', $folder

        Write-Output "  Executing Gingko Command: '$cmd'.."
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            break
        }
    }
}

function Start-PesterTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [ValidateSet('None', 'Run', 'Container', 'Block')]
        [string]
        $SkipRemainingOnFailure = 'None',
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false
    )
    Write-Output "Executing Powershell tests in '$WorkingDir' with verbose='$V' for tags '$Tags' and excluding tags '$ExcludeTags'.."

    $pesterConf = New-PesterConfiguration
    $pesterConf.Run.Path = $WorkingDir
    $pesterConf.Run.SkipRemainingOnFailure = $SkipRemainingOnFailure
    $pesterConf.Filter.Tag = $Tags
    $pesterConf.Filter.ExcludeTag = $ExcludeTags
    $pesterConf.TestResult.Enabled = $true
    $pesterConf.TestResult.OutputPath = $OutDir + '\PowershellTest-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString() + '.xml'

    if ($V -eq $true) {
        $pesterConf.Output.Verbosity = 'Detailed'
    }

    Invoke-Pester -Configuration $pesterConf
}

Export-ModuleMember -Function Install-PesterIfNecessary, Install-GinkgoIfNecessary, Start-PesterTests, Start-GinkgoTests