# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Build a new Docker image on the Linux VM or on Windows host

.DESCRIPTION
Builds a Linux docker image or a Windows container image in the K2s setup on the Linux VM.
Optionally pushes the created image to the repository (only with -Push)

With -Push, the image will be pushed even if there is already an image with same tag
on the repository, the old image will then be lost! Be careful!

Without an explicit -ImageTag, the tag 'local' will be used. This can't be pushed to
repository, it is only for local tests.

-InputFolder is optional, defaults to current directory
-ImageName is optional, default is taken from content of dockerfile

Modes of creation:
- PreCompile (Dockerfile.Precompile): default, it copies sources to Linux VM and compiles there the executable inside the VM and builds the container
- Full (Dockerfile): use this multi stage dockerfile, where image is build within docker file and container images afterwards
Note: Precompile is the best compromise in most cases since it reuses during build many cached components inside the VM
and build natively inside Linux the image.

In order to install a build environment on your machine call 'powershell <installation folder>\common\InstallBuildOnlySetup.ps1 [-Offline]'
By omitting the flag 'Offline' a new Linux image is created and is made available on your machine.
By using the flag 'Offline' the Linux VM is set up using a pre-built Linux image that is already available on your machine.

Another alternative to setup a build environment is by using the normal K2s Setup.

.EXAMPLE
PS> .\BuildImage.ps1
PS> .\BuildImage.ps1 -InputFolder D:\tests\go\tstserver -ImageName k2s-registry.local/testserver
PS> .\BuildImage.ps1 -ImageName k2s-registry.local/testserver -ImageTag 76 -Push
PS> .\BuildImage.ps1 -PreCompile -Tag 99 -Optimize -Distroless -NoCGO

#>

Param(
    [Alias('d')]
    [parameter(Mandatory = $false, HelpMessage = 'Directory with the Dockerfile')]
    [string] $InputFolder = '.',

    [Alias('f')]
    [parameter(Mandatory = $false, HelpMessage = 'Name of the Dockerfile')]
    [string] $Dockerfile = '',

    [parameter(Mandatory = $false, HelpMessage = 'Name of the created image')]
    [string] $ImageName = '',

    [Alias('t', 'Tag')]
    [parameter(Mandatory = $false, HelpMessage = 'Tag in registry')]
    [string] $ImageTag = 'local',

    [Alias('p')]
    [parameter(Mandatory = $false, HelpMessage = 'Push image to repository')]
    [switch] $Push = $false,

    [parameter(Mandatory = $false, HelpMessage = "Don't use cache in Docker build")]
    [switch] $NoCache = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Optimize for size')]
    [switch] $Optimize = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use bindings for C')]
    [switch] $NoCGO = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use distroless base image')]
    [switch] $Distroless = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Keep the colored output from Docker build')]
    [switch] $KeepColor = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Keep temporary directory on VM')]
    [switch] $Keep = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Precompile outside of container')]
    [switch] $PreCompile = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Build a windows container image')]
    [switch] $Windows = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use a gitconfig with --secret during docker build')]
    [string] $GitConfigWithSecrets = '',

    [parameter(Mandatory = $false, HelpMessage = 'Use a npmrc with --secret during docker build')]
    [string] $NpmRcWithSecrets = '',

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Build Arguments for building container image')]
    [string[]] $BuildArgs = @(),
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\GlobalVariables.ps1
. $PSScriptRoot\GlobalFunctions.ps1

$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\..\helpers\ImageFunctions.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $clusterModule, $imageFunctionsModule, $logModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

function Get-DockerfileAbsolutePathAndPrecompileFlag() {
    if ($Dockerfile -ne '') {
        $filePath = ''
        try {
            # try to resolve the path relative to current working directory first.
            $filePath = (Resolve-Path -Path $Dockerfile -ErrorAction Stop).Path
        }
        catch {
            # if this fails, try to resolve it relative to Input folder.
            # if this also fails, stop execution
            Write-Log "Could not resolve Dockerfile from current working directory. We will now try to resolve it from $InputFolder"
            if (! (Test-Path "$InputFolder\$Dockerfile")) { throw 'Unable to find Dockerfile' }
            $filePath = "$InputFolder\$Dockerfile"
        }
        # We return PreCompile flag
        return $filePath, $PreCompile
    }

    if ($Dockerfile -eq '' -and $PreCompile) {
        $Dockerfile = 'Dockerfile.PreCompile'
        Write-Log "Pre-Compilation: using $Dockerfile"
    }

    # set defaults if no dockerfile given: If Dockerfile.PreCompile is available, use that,
    # otherwise use Dockerfile
    if ($Dockerfile -eq '') {
        $Dockerfile = 'Dockerfile.PreCompile'
        if (Test-Path "$InputFolder\$Dockerfile") {
            $PreCompile = $True
            Write-Log "Pre-Compilation: using $Dockerfile"
        }
        else {
            $Dockerfile = 'Dockerfile'
            Write-Log "Full: using $Dockerfile"
        }
    }
    if (! (Test-Path "$InputFolder\$Dockerfile")) { throw "Missing Dockerfile: $InputFolder\$Dockerfile" }

    $filePath = "$InputFolder\$Dockerfile"
    return $filePath, $PreCompile
}

function Get-BuildArgs() {
    $buildArgString = ''
    foreach ($buildArgValuePair in $BuildArgs) {
        $array = $buildArgValuePair.Split('=')
        $name = $array[0]
        $value = $array[1]
        $buildArgString += "--build-arg $name=$value "
    }
    if ($buildArgString.Length -gt 0) {
        $buildArgString = $buildArgString.Substring(0, $buildArgString.Length - 1)
    }
    return $buildArgString
}

function BuildWindowsImage () {
    param(
        [Parameter()]
        [String] $InputFolder,
        [Parameter()]
        [String] $Dockerfile,
        [Parameter()]
        [String] $ImageName,
        [Parameter()]
        [String] $ImageTag,
        [Parameter()]
        [String] $NoCacheFlag,
        [Parameter()]
        [String] $BuildArgsString
    )
    $shouldStopDocker = $false
    $svc = (Get-Service 'docker' -ErrorAction Stop)
    if ($svc.Status -ne 'Running') {
        Write-Log 'Starting docker backend...'
        Start-Service docker
        $shouldStopDocker = $true
    }

    $imageFullName = "${ImageName}:$ImageTag"

    Write-Log "Building Windows image $imageFullName" -Console
    if ($BuildArgsString -ne '') {
        $cmd = "$global:DockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName $BuildArgsString"
        Write-Log "Build cmd: $cmd"
        Invoke-Expression -Command $cmd
    }
    else {
        $cmd = "$global:DockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName"
        Write-Log "Build cmd: $cmd"
        Invoke-Expression -Command $cmd
    }
    if ($LASTEXITCODE -ne 0) { throw "error while creating image with 'docker build' on Windows. Error code returned was $LastExitCode" }

    Write-Log "Output of checking if the image $imageFullName is now available in docker:"
    &$global:DockerExe image ls $ImageName -a

    Write-Log $global:ExportedImagesTempFolder
    if (!(Test-Path($global:ExportedImagesTempFolder))) {
        New-Item -Force -Path $global:ExportedImagesTempFolder -ItemType Directory
    }
    $exportedImageFullFileName = $global:ExportedImagesTempFolder + '\BuiltImage.tar'
    if (Test-Path($exportedImageFullFileName)) {
        Remove-Item $exportedImageFullFileName -Force
    }

    Write-Log "Saving image $imageFullName temporarily as $exportedImageFullFileName to import it afterwards into containerd..."
    &$global:DockerExe save -o "$exportedImageFullFileName" $imageFullName
    if (!$?) { throw "error while saving built image '$imageFullName' with 'docker save' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...saved.'

    Write-Log "Importing image $imageFullName from $exportedImageFullFileName into containerd..."
    &$global:NerdctlExe -n k8s.io load -i "$exportedImageFullFileName"
    if (!$?) { throw "error while importing built image '$imageFullName' with 'nerdctl.exe load' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...imported'

    Write-Log "Removing temporarily created file $exportedImageFullFileName..."
    Remove-Item $exportedImageFullFileName -Force
    Write-Log '...removed'

    $imageList = &$global:CtrExe -n="k8s.io" images list 2>&1 | Out-string

    if (!$imageList.Contains($imageFullName)) {
        throw "The built image '$imageFullName' was not imported in the containerd's local repository."
    }
    Write-Log "The built image '$imageFullName' is available in the containerd's local repository."

    if ($shouldStopDocker) {
        Write-Log 'Stopping docker backend...'
        Stop-Service docker
    }
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$GO_Ver = '1.22.3' # default go version
if ($null -ne $env:GOVERSION -and $env:GOVERSION -ne '') {
    Write-Log "Using local GOVERSION $Env:GOVERSION environment variable from the host machine"
    # $env:GOVERSION will be go1.22.3, remove the go part.
    $GO_Ver = $env:GOVERSION -split 'go' | Select-Object -Last 1
}

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

$scriptStartLocation = Get-Location
Write-Log "Script start location: $scriptStartLocation"

$buildArgsString = Get-BuildArgs
if ($buildArgsString -ne '') {
    Write-Log "Build arguments $buildArgsString"
}

# make absolute path
$InputFolder = [System.IO.Path]::GetFullPath($InputFolder)

$dockerfileAbsoluteFp, $PreCompile = Get-DockerfileAbsolutePathAndPrecompileFlag

if (($ImageTag -eq 'local') -and $Push) {
    $errMsg = 'Unable to push without valid tag, use -ImageTag'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'build-image-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "Using Dockerfile: $dockerfileAbsoluteFp" -Console

$WSL = Get-WSLFromConfig

if (!$Windows) {
    if ($WSL) {
        if ($(wsl -l --running) -notcontains 'KubeMaster (Default)') {
            $errMsg = "WSL Distro $global:VMName is not started, execute 'k2s start' first!"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-image-failed' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }
    }
}

if ($Push) {
    if (!$ImageName.Contains('/')) {
        $errMsg = 'Please check ImageName! Cannot extract registry name!'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    $split = $($ImageName -split '/')

    $registry = $split[0]

    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json
    $registriesMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if (!$registriesMemberExists) {
        $errMsg = "Registry $registry is not configured! Please add it: k2s image registry add $registry"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    $registryExists = $parsedSetupJson.Registries | Where-Object { $_ -eq $registry }
    if (!$registryExists) {
        $errMsg = "Registry $registry is not configured! Please add it: k2s image registry add $registry"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    &$PSScriptRoot\..\helpers\SwitchRegistry.ps1 -RegistryName $registry
}

# Handle CGO flags
$CGOFlags = 'CC=musl-gcc CGO_ENABLED=1'
$env:CGO_ENABLED = '1'
if ( $NoCGO ) {
    $CGOFlags = 'CGO_ENABLED=0'
    $env:CGO_ENABLED = '0'
}

# Handle parameters from dockerfile
$ImageNameFromDockerfile = ''
$ccExecutableName = ''
$GoBuild = 'build'
Get-Content $dockerfileAbsoluteFp | ForEach-Object {
    if ($_ -match '^# *ExeName: +(\S+)') {
        $ccExecutableName = $matches[1]
    }
    if ($_ -match '^# *ImageName: +(\S+)') {
        $ImageNameFromDockerfile = $matches[1]
    }
    if ($_ -match '^# *GoBuild: +(\S+)') {
        $GoBuild = $matches[1]
    }
    if ($_ -match '^# *ImageType: +Windows') {
        $Windows = $true
    }
}
if ($ImageName -eq '') {
    if ($ImageNameFromDockerfile -eq '') { throw "Missing ImageName in $InputFolder\$Dockerfile, and no -ImageName parameter given" }
    $ImageName = $ImageNameFromDockerfile
    Write-Log "Using ImageName from Dockerfile: $ImageName"
}

$setupInfo = Get-SetupInfo
if ($Windows -and $setupInfo.LinuxOnly) {
    $errMsg = 'Linux-only setup does not support building Windows images'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($ccExecutableName -eq '' -and $PreCompile ) {
    $errMsg = "Missing ExeName in $InputFolder\$Dockerfile"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'build-image-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Set-Location $InputFolder
$BuildDirFromDockerfile = '..'
Set-Location $BuildDirFromDockerfile
Write-Log "Using BuildDirFromDockerfile: $BuildDirFromDockerfile"
Copy-Item $dockerfileAbsoluteFp Dockerfile.ForBuild.tmp

if ($Distroless -and $NoCGO ) {
    $file = 'Dockerfile.ForBuild.tmp'
    $line = Get-Content $file | select-string 'FROM' | Select-Object -ExpandProperty Line
    (Get-Content ($file)) | Foreach-Object { $_ -replace "$line", ('FROM gcr.io/distroless/static-debian11') } | Set-Content ($file)
}

$GitConfigWithSecretsArg = ''
$NpmSecretsArg = ''

if ($GitConfigWithSecrets -ne '') {
    # Copy git config
    Write-Log "Copy $GitConfigWithSecrets to gitconfig"
    attrib -r Dockerfile.ForBuild.tmp
    Copy-Item $GitConfigWithSecrets gitconfig
    attrib -r gitconfig
    $GitConfigWithSecretsArg = '--secret id=gitconfig,src=gitconfig'
}

if ($NpmRcWithSecrets -ne '') {
    # Copy npmrc config
    Write-Log "Copy $NpmRcWithSecrets to .npmrc"
    Copy-Item $NpmRcWithSecrets .npmrc
    attrib -r .npmrc
    $NpmSecretsArg = '--secret id=npmrc,src=.npmrc'
}

# Linux Precompile & Full: copy source files to VM
if (!$Windows) {
    Write-Log "Copying needed source files into $global:VMName VM from $InputFolder" -Console
    $targetpath = 'tmp/docker-build/' + $(Split-Path -Leaf $InputFolder)
    $target = "$global:Remote_Master" + ":$targetpath"
    ExecCmdMaster "test -d ~/tmp/docker-build && find ~/tmp/docker-build -exec chmod a+w {} \; ; rm -rf ~/tmp/docker-build; mkdir -p ~/tmp/docker-build; mkdir -p $targetpath;mkdir -p ~/tmp/docker-build/common"
    $source = $InputFolder
    Write-Log "Copying $source to $target"
    Get-ChildItem -Path $source -Exclude 'node_modules', 'dist', '.angular' | % { $n = $_.Name ; Write-Log "Copying $source\$n to $target"; Copy-FromToMaster "$source/$n" $target }

    # copy gitconfig
    $source = $InputFolder + '\..\gitconfig'
    $target = "$global:Remote_Master" + ':tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-FromToMaster $source $target -IgnoreErrors

    # copy .npmrc
    $source = $InputFolder + '\..\.npmrc'
    $target = "$global:Remote_Master" + ':tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-FromToMaster $source $target -IgnoreErrors

    # copy Dockerfile.ForBuild.tmp
    $source = $InputFolder + '\..\Dockerfile.ForBuild.tmp'
    $target = "$global:Remote_Master" + ':tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-FromToMaster $source $target

    # copy common if avaliable
    $source = $InputFolder + '\..\common'
    if ( Test-Path -Path $source ) {
        $target = "$global:Remote_Master" + ':tmp/docker-build/common'
        Write-Log "Copying $source to $target"
        Copy-FromToMaster "$source\*" $target
    }
}

# Linux Precompile: build inside VM images
if (!$Windows -and $PreCompile) {
    #Set-PSDebug -Trace 1
    Write-Log "Pre-Compilation: Build inside $global:VMName VM"

    if ($GitConfigWithSecrets -ne '') {
        Write-Log 'Pre-Compilation: creating ~/.gitconfig in VM'
        Copy-FromToMaster 'gitconfig' ($global:Remote_Master + ':.gitconfig') | Out-Null
    }

    # check if we need to install go and gcc into VM
    $GoInstalled = $(ExecCmdMaster "which /usr/local/go-$GO_Ver/bin/go" -NoLog)
    $MuslInstalled = $(ExecCmdMaster 'which musl-gcc' -NoLog)
    if ($GoInstalled -match '/bin/go' -and $MuslInstalled -match '/bin/musl-gcc') {
        Write-Log 'Pre-Compilation: go and gcc compiler already available in VM'
    }
    else {
        Write-Log 'Pre-Compilation: Downloading needed binaries (go, gcc)...'
        ExecCmdMaster "echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections"
        ExecCmdMaster 'sudo apt-get update;DEBIAN_FRONTEND=noninteractive sudo apt-get install -q --yes gcc git musl musl-tools;' -Retries 3 -Timeout 2
        ExecCmdMaster 'DEBIAN_FRONTEND=noninteractive sudo apt-get install -q --yes upx-ucl' -Retries 3 -Timeout 2
        # ExecCmdMaster "sudo apt-get update >/dev/null ; sudo apt-get install -q --yes golang-$GO_Ver gcc git musl musl-tools; sudo apt-get install -q --yes upx-ucl"
        if ($LASTEXITCODE -ne 0) {
            throw "'apt install' returned code $LASTEXITCODE. Aborting. In case of timeouts do a retry."
        }

        # Install Go
        $goInstallScript = '/tmp/install_go.sh'
        $copyGoInstallScript = "$global:Remote_Master" + ':' + $goInstallScript
        Copy-FromToMaster "$global:KubernetesPath\smallsetup\linuxnode\scripts\install_go.sh" $copyGoInstallScript
        # After copy we need to remove carriage line endings from the shell script.
        # TODO: Function to copy shell script to Linux host and remove CR in the shell script file before execution
        ExecCmdMaster "sed -i -e 's/\r$//' $goInstallScript" -NoLog
        ExecCmdMaster "chmod +x $goInstallScript" -NoLog
        ExecCmdMaster "$goInstallScript $GO_Ver 2>&1"
    }

    $dirForBuild = '~/tmp/docker-build'
    if ($BuildDirFromDockerfile -ne '') {
        if ($BuildDirFromDockerfile -eq '..') {
            $dirForBuild = $dirForBuild + '/' + $(Split-Path -Leaf $InputFolder)
            Write-Log "Pre-Compilation: Building in VM in $dirForBuild ..."
        }
        else {
            $errMsg = "currently only '..' is allowed as value for DockerBuildDir"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-image-failed' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }
    }

    $setTransparentProxy = ''
    switch (Get-Installedk2sSetupType) {
        'k2s' {
            $setTransparentProxy = 'export HTTPS_PROXY=http://' + $global:IP_NextHop + ':8181;'
        }
        Default {}
    }

    $setGoEnvironment = 'GOPRIVATE=dev.azure.com'
    if ($Env:GOPRIVATE -ne '') {
        Write-Log 'Using your local GOPRIVATE environment variable on the build host'
        $setGoEnvironment = "GOPRIVATE=$Env:GOPRIVATE"
    }
    if ($Env:GOPROXY -ne '') {
        Write-Log 'Using your local GOPROXY environment variable on the build host'
        $setGoEnvironment = "$setGoEnvironment GOPROXY=$Env:GOPROXY"
    }
    if ($Env:GOSUMDB -ne '') {
        Write-Log 'Using your local GOSUMDB environment variable on the build host'
        $setGoEnvironment = "$setGoEnvironment GOSUMDB=$Env:GOSUMDB"
    }

    if ($GoBuild -eq 'test') {
        Write-Log "Pre-Compilation: Building test-executable with GO: $ccExecutableName ..."
        ExecCmdMaster "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_Ver/bin/go test -c -v -o $ccExecutableName 2>&1"
    }
    else {
        Write-Log "Getting dependencies for GO: $ccExecutableName ..."
        ExecCmdMaster "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment /usr/local/go-$GO_Ver/bin/go get -v . 2>&1"

        if ( $Optimize ) {
            Write-Log "Pre-Compilation: Building optimized executable with GO: $ccExecutableName ..."
            ExecCmdMaster "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_Ver/bin/go build -v -ldflags='-s -w' -o $ccExecutableName . 2>&1; upx $ccExecutableName ; ls -l"
        }
        else {
            Write-Log "Pre-Compilation: Building executable with GO: $ccExecutableName ..."
            ExecCmdMaster "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_Ver/bin/go build -v -o $ccExecutableName . 2>&1"
        }
    }
    if ($LASTEXITCODE -ne 0) {
        $errMsg = "go returned code $LASTEXITCODE. Aborting."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

if ($NoCache) {
    $NoCacheFlag = '--no-cache'
}
else {
    $NoCacheFlag = ''
}

if ($KeepColor -or $Windows) {
    $RemoveColorSequences = ''
}
else {
    # 'go get' outputs all download commands to stderr, which is then converted by 'docker build'
    # into red text with ANSI escape sequences. This is all hardcoded, and we don't want that.
    # So we remove these ANSI sequences with a sed command. The 'unbuffer' from package 'expect'
    # is needed to avoid buffering of output, we want to see it line by line, not as one big
    # block after the process has finished.
    $RemoveColorSequences = " 2>&1 | unbuffer -p sed 's/\x1b\[[0-9;]*m//g'; eval test $\{PIPESTATUS[0]} -eq 0 || exit 1"
    $UnbufferInstalled = $(ExecCmdMaster 'which unbuffer' -NoLog)
    if ($UnbufferInstalled -match 'unbuffer') {
        Write-Log "Found unbuffer command ('expect' package)"
    }
    else {
        Write-Log "Installing unbuffer command ('expect' package)"
        ExecCmdMaster 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -q --yes expect'
        $UnbufferInstalled = $(ExecCmdMaster 'which unbuffer' -NoLog)
        if (! ($UnbufferInstalled -match 'unbuffer')) {
            Write-Log 'Unable to install unbuffer command, keeping ANSI sequences'
            $RemoveColorSequences = ''
        }
    }
}

# Windows container
if ($Windows) {
    if ($setupInfo.Name -eq "$global:SetupType_MultiVMK8s") {
        $dockerBuildPath = 'C:\temp\docker-build'
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode rmdir /s /q $dockerBuildPath
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode mkdir $dockerBuildPath

        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey
        Copy-Item "$InputFolder" -Destination "$dockerBuildPath" -Recurse -ToSession $session -Force
        Copy-Item "${InputFolder}\..\Dockerfile.ForBuild.tmp" -Destination "$dockerBuildPath" -Recurse -ToSession $session -Force
        
        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

            # load global settings
            &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
            # import global functions
            . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        }
        Invoke-Command -Session $session -ScriptBlock ${Function:BuildWindowsImage} -ArgumentList "${dockerBuildPath}\$(Split-Path -Leaf $InputFolder)", 'C:\temp\docker-build\Dockerfile.ForBuild.tmp', $ImageName, $ImageTag, $NoCacheFlag, $buildArgsString
    }
    else {
        BuildWindowsImage -InputFolder $InputFolder -Dockerfile 'Dockerfile.ForBuild.tmp' -ImageName $ImageName -ImageTag $ImageTag -NoCacheFlag $NoCacheFlag -BuildArgsString $buildArgsString
    }
}
else {
    Write-Log "Building container image using Buildah inside $global:VMName VM" -Console
    Write-Log "with gitconfig and npmrc: $GitConfigWithSecretsArg $NpmSecretsArg"
    $buildContextFolder = $(Split-Path -Leaf $InputFolder)
    $buildahBudCommand = "cd ~/tmp/docker-build; sudo buildah bud -f Dockerfile.ForBuild.tmp --force-rm --no-cache $GitConfigWithSecretsArg $NpmSecretsArg -t ${ImageName}:$ImageTag $buildContextFolder $RemoveColorSequences 2>&1"
    if ($buildArgsString -ne '') {
        $buildahBudCommand = "cd ~/tmp/docker-build; sudo buildah bud $buildArgsString -f Dockerfile.ForBuild.tmp --force-rm --no-cache $GitConfigWithSecretsArg $NpmSecretsArg -t ${ImageName}:$ImageTag $buildContextFolder $RemoveColorSequences 2>&1"
        Write-Log $buildahBudCommand
    }
    ExecCmdMaster "$buildahBudCommand"
    if ($LASTEXITCODE -ne 0) {
        $errMsg = "error while creating image with 'buildah bud' in linux VM. Error code returned was $LastExitCode"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    Write-Log ''
    ExecCmdMaster "sudo buildah images | grep ${ImageName}"
}

# Cleanup on host
if (Test-Path '.\Dockerfile.ForBuild.tmp') {
    Remove-Item '.\Dockerfile.ForBuild.tmp'
}
if (Test-Path '.\gitconfig') {
    Remove-Item '.\gitconfig'
}
if (Test-Path '.\.npmrc') {
    Remove-Item '.\.npmrc'
}

# Push image to registry
if ($Push) {
    Write-Log "Trying to push image ${ImageName}:$ImageTag to repository" -Console

    if ($Windows) {
        if ($setupInfo.Name -eq "$global:SetupType_MultiVMK8s") {
            ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey docker push "${ImageName}:$ImageTag" 2>&1
        }
        else {
            &$global:DockerExe push "${ImageName}:$ImageTag" 2>&1
        }
    }
    else {
        ExecCmdMaster "sudo buildah push ${ImageName}:$ImageTag 2>&1"
    }

    if (!$?) {
        Write-Log '#######################################################################################'
        Write-Log "### ERROR: image ${ImageName}:$ImageTag NOT uploaded to repository"
        Write-Log '#######################################################################################'

        $errMsg = 'unable to push image to registry'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    Write-Log "Image '${ImageName}:$ImageTag' pushed successfully to registry" -Console
}

# Cleanup inside VM
if (!$Keep -and ! $Windows) {
    Write-Log "Cleaning up temporary disk space in $global:VMName VM" -Console
    #ExecCmdMaster 'find ~/tmp/docker-build -exec chmod a+w {} \; ; rm -rf ~/tmp/docker-build'
}

Write-Log "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"

Set-Location $scriptStartLocation

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}