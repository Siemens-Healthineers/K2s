# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

#######################################################################################################
###                                        FUNCTIONS                                                ###
#######################################################################################################

function
Convert-WinImage {
    <#
    .SYNOPSIS
        Minimalistic Script to Create a bootable VHD(X) based on Windows 10 installation media.
        See https://github.com/Microsoft/Virtualization-Documentation/tree/master/hyperv-tools/Convert-WindowsImage

    .EXAMPLE
        .\Convert-WinImage.ps1 -IsoPath D:\foo\install.wim -Edition Professional -DiskLayout UEFI

        This command will create a 40GB dynamically expanding VHD in a WorkingDirectory.
        The VHD will be based on the Professional edition from Source ISO, and will be named automatically.

    .OUTPUTS
        System.IO.FileInfo if PassThru is enabled
    #>
    #Requires -RunAsAdministrator

    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $IsoPath,

        [string[]]
        [ValidateNotNullOrEmpty()]
        $WinEdition,

        [string]
        [ValidateNotNullOrEmpty()]
        $VHDPath,

        [UInt64]
        [ValidateNotNullOrEmpty()]
        [ValidateRange(1GB, 64TB)]
        $SizeBytes = 25GB,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('VHD', 'VHDX', 'AUTO')]
        $VHDFormat = 'AUTO',

        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
        $DiskLayout,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $UnattendDir,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        $WorkingDir = $pwd,

        [string]
        [ValidateNotNullOrEmpty()]
        $TempDir = $env:Temp,

        [switch]
        $CacheSrc = $false,

        [switch]
        $Passthru
    )

    Begin {
        #Logging Variables
        $scriptName = 'Convert-WinImage'
        $sessionKey = [Guid]::NewGuid().ToString()
        $logDir = "$($TempDir)\$($scriptName)\$($sessionKey)"

        #VHD Limits and Supported Version
        $vhdMaxSize = 2040GB
        $lowestSupportedBuild = 9200

        $winBuildNumber = [int]($(Get-CimInstance -Class Win32_OperatingSystem).BuildNumber)
        $VHDFormat = $VHDFormat.ToUpper()

        Function Run-Exe {
            param([string]$Executable, [string[]]$ExeArgs, [int]$ExpectedExitCode = 0)

            Write-Log "Running EXE $Executable with args: $ExeArgs"
            $exeProc = Start-Process           `
                -FilePath $Executable      `
                -ArgumentList $ExeArgs     `
                -NoNewWindow               `
                -RedirectStandardError "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardError.txt"  `
                -RedirectStandardOutput "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardOutput.txt" `
                -Passthru

            $execHandle = $exeProc.Handle # WORKAROUND!! POWERSHELL BUG https://github.com/PowerShell/PowerShell/issues/20716, Need to cache handle in order to get the exit code.
            $exeProc.WaitForExit()

            Write-Log "Executable Return Code: $($exeProc.ExitCode)."

            if ($exeProc.ExitCode -ne $ExpectedExitCode) {
                throw "$Executable execution failed with code $($exeProc.ExitCode)"
            }
        }

        Function Test-IsNetPath
        {
            param([string]$Path)

            try {
                $uri = New-Object System.Uri -ArgumentList $Path

                if ($uri.IsUnc) {
                    return $true
                }

                $drive = Get-PSDrive -PSProvider 'FileSystem' -Name ($uri.LocalPath.Substring(0, 1)) -ErrorAction Stop

                if ($drive.Root -like '\\*') {
                    return $true
                }
            }
            catch {
                Write-Error "Invalid path: $_"
            }

            return $false
        }
    }

    Process {

        $vhdDiskNumber = $null
        $openIso = $null
        $wim = $null
        $vhdFinalName = $null
        $vhdFinalPath = $null
        $isoFinalPath = $null
        $tempSource = $null
        $BCDBoot = 'bcdboot.exe'

        Write-Log "Source Path $IsoPath..."

        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            try {
                $hyperVEnabled = $((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled')
            }
            catch {
                $hyperVEnabled = $false
            }
        }
        else {
            $hyperVEnabled = $false
        }

        $vhd = @()

        try {
            if (Test-Path $logDir) {
                $null = Remove-Item $logDir -Force -Recurse
            }

            $null = mkdir $logDir -Force

            if (!($winBuildNumber -ge [int]$lowestSupportedBuild)) {
                throw "$scriptName requires Windows 8 or higher."
            }

            if ($VHDFormat -ilike 'AUTO') {
                if ($DiskLayout -eq 'BIOS') {
                    $VHDFormat = 'VHD'
                }
                else {
                    $VHDFormat = 'VHDX'
                }
            }

            if (![string]::IsNullOrEmpty($UnattendDir)) {
                $UnattendDir = (Resolve-Path $UnattendDir).Path
            }

            # We assign smallest supported block size for Dynamic VHD(X)
            $VHDBlockSizeBytes = 1MB

            if ('VHD' -ilike $VHDFormat) {
                if ($SizeBytes -gt $vhdMaxSize) {
                    Write-Warning "For the VHD file format, the maximum file size is ~2040GB.  We will automatically set size to 2040GB..."
                    $SizeBytes = $vhdMaxSize
                }

                $VHDBlockSizeBytes = 512KB
            }


            if ((![String]::IsNullOrEmpty($VHDPath)) -and (![String]::IsNullOrEmpty($WorkingDir))) {
                if ($WorkingDir -ne $pwd) {
                    Write-Warning 'Ignoring the WorkingDirectory specification. Specifying -VHDPath and -WorkingDirectory at the same time is contradictory!'
                    $WorkingDir = Split-Path $VHDPath -Parent
                }
            }

            if ($VHDPath) {
                $fileExt = ([IO.FileInfo]$VHDPath).Extension
                if (!($fileExt -ilike ".$($VHDFormat)")) {
                    throw "There is a mismatch between the file extensions VHDPath file ext: ($($fileExt.ToUpper())), and VHDFormat: (.$($VHDFormat)). Ensure that they match and try again"
                }
            }

            # Creating a temporary name for the VHD(x). We shall name it at the end of the script.
            if ([String]::IsNullOrEmpty($VHDPath)) {
                $VHDPath = Join-Path $WorkingDir "$($sessionKey).$($VHDFormat.ToLower())"
            }
            else {
                if (![IO.Path]::IsPathRooted($VHDPath)) {
                    $VHDPath = Join-Path $WorkingDir $VHDPath
                }

                $vhdFinalName = Split-Path $VHDPath -Leaf
                $VHDPath = Join-Path (Split-Path $VHDPath -Parent) "$($sessionKey).$($VHDFormat.ToLower())"
            }

            Write-Log "Temporary $VHDFormat path is : $VHDPath"

            # Here if input is an ISO, first mount it and obtain the path to the WIM file.
            if (([IO.FileInfo]$IsoPath).Extension -ilike '.ISO') {
                # If the ISO isn't local, copy it down.
                if (Test-IsNetPath $IsoPath) {
                    Write-Log "Copying ISO $(Split-Path $IsoPath -Leaf) to temp folder..."
                    robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                    $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"

                    $tempSource = $IsoPath
                }

                $isoFinalPath = (Resolve-Path $IsoPath).Path

                Write-Log "Opening ISO $(Split-Path $isoFinalPath -Leaf)..."
                $openIso = Mount-DiskImage -ImagePath $isoFinalPath -StorageType ISO -PassThru
                $openIso = Get-DiskImage -ImagePath $isoFinalPath
                $driveLetter = ($openIso | Get-Volume).DriveLetter

                $IsoPath = "$($driveLetter):\sources\install.wim"

                Write-Log "Looking for $($IsoPath)..."
                if (!(Test-Path $IsoPath)) {
                    throw 'The specified ISO does not appear to be valid Windows installation media.'
                }
            }

            if (Test-IsNetPath $IsoPath) {
                Write-Log "Copying WIM $(Split-Path $IsoPath -Leaf) to temp folder..."
                robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"
                $tempSource = $IsoPath
            }

            $IsoPath = (Resolve-Path $IsoPath).Path

            # Now lets query wim information and obtain the index of targeted image

            Write-Log 'Searching for requested Windows Image in the WIM file'
            $WindowsImage = Get-WindowsImage -ImagePath $IsoPath

            if (-not $WindowsImage -or ($WindowsImage -is [System.Array])) {
                $WinEditionIndex = 0;
                if ([Int32]::TryParse($WinEdition, [ref]$WinEditionIndex)) {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath -Index $WinEditionIndex
                }
                else {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath | Where-Object { $_.ImageName -ilike "*$($WinEdition)" }
                }

                if (-not $WindowsImage) {
                    throw 'Requested windows Image was not found on the WIM file!'
                }

                if ($WindowsImage -is [System.Array]) {
                    Write-Log "WIM file has the following $($WindowsImage.Count) images that match filter *$($WinEdition)"
                    Get-WindowsImage -ImagePath $IsoPath

                    Write-Error 'You must specify an Edition or SKU index, since the WIM has more than one image.'
                    throw "There are more than one images that match ImageName filter *$($WinEdition)"
                }
            }

            $ImageIndex = $WindowsImage[0].ImageIndex

            $wim = Get-WindowsImage -ImagePath $IsoPath -Index $ImageIndex

            if ($null -eq $wim) {
                Write-Error 'The specified edition does not appear to exist in the specified WIM.'
                throw
            }

            Write-Log "Image $($wim.ImageIndex) selected ($($wim.EditionId))..."

            if ($hyperVEnabled) {
                Write-Log 'Creating VHD sparse disk...'
                $newVhd = New-VHD -Path $VHDPath -SizeBytes $SizeBytes -BlockSizeBytes $VHDBlockSizeBytes -Dynamic

                Write-Log "Mounting $VHDFormat and Getting Disk..."
                $vhdDisk = $newVhd | Mount-VHD -PassThru | Get-Disk
                $vhdDiskNumber = $vhdDisk.Number
            }
            else {
                throw "Convert-WindowsImage only supports Hyper-V based VHD creation."
            }

            switch ($DiskLayout) {
                'BIOS' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    # Create the Windows/system partition
                    Write-Log 'Creating single partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS -IsActive
                    $windowsPartition = $systemPartition

                    Write-Log 'Formatting windows volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem NTFS -Force -Confirm:$false
                    $windowsVolume = $systemVolume
                }

                'UEFI' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle GPT

                    if (($winBuildNumber) -ge 10240) {
                        # Create the system partition.  Create a data partition so we can format it, then change to ESP
                        Write-Log 'Creating EFI system partition...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                        Write-Log 'Formatting system volume...'
                        $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                        Write-Log 'Setting system partition as ESP...'
                        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                        $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
                    }
                    else {
                        # Create the system partition
                        Write-Log 'Creating EFI system partition (ESP)...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter

                        Write-Log 'Formatting ESP...'
                        # /Q Quick format, /Y Suppress Prompt, /FS File System
                        $formatArgs = @("$($systemPartition.DriveLetter):", '/FS:FAT32', '/Q', '/Y')

                        Run-Exe -Executable format -ExeArgs $formatArgs
                    }

                    # Create the reserved partition
                    Write-Log 'Creating MSR partition...'
                    New-Partition -DiskNumber $vhdDiskNumber -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

                    # Create the Windows partition
                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }

                'WindowsToGo' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    Write-Log 'Creating system partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 350MB -MbrType FAT32 -IsActive

                    Write-Log 'Formatting system volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }
            }

            # Assign drive letter to Windows partition.  This is required for bcdboot.
            $attempts = 1
            $assigned = $false

            do {
                $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
                $windowsPartition = $windowsPartition | Get-Partition
                if ($windowsPartition.DriveLetter -ne 0) {
                    $assigned = $true
                }
                else {
                    #sleep for up to 10 seconds and retry
                    Get-Random -Minimum 1 -Maximum 10 | Start-Sleep

                    $attempts++
                }
            }
            while ($attempts -le 25 -and -not($assigned))

            if (-not($assigned)) {
                throw 'Unable to get Partition after retry'
            }

            $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0, 2)
            Write-Log "Windows path ($windowsDrive) has been assigned."
            Write-Log "Windows path ($windowsDrive) took $attempts attempts to be assigned."

            # Refresh access paths (we have now formatted the volume)
            $systemPartition = $systemPartition | Get-Partition
            $systemDrive = $systemPartition.AccessPaths[0].trimend('\').replace('\?', '??')
            Write-Log "System volume location: $systemDrive"

            # APPLY IMAGE FROM WIM TO THE NEW VHD WHICH IS CREATED

            Write-Log "Applying image in format $VHDFormat. This will take a while..."
            if ((Get-Command Expand-WindowsImage -ErrorAction SilentlyContinue)) {
                Expand-WindowsImage -ApplyPath $windowsDrive -ImagePath $IsoPath -Index $ImageIndex -LogPath "$($logDir)\DismLogs.log" | Out-Null
            }
            else {
                throw 'Image Apply failed! See DismImageApply logs for details'
            }
            Write-Log 'Image was applied successfully. '

            # Copy the unattend file
            if (![string]::IsNullOrEmpty($UnattendDir)) {
                Write-Log "Applying unattend file ($(Split-Path $UnattendDir -Leaf))..."
                Copy-Item -Path $UnattendDir -Destination (Join-Path $windowsDrive 'unattend.xml') -Force
            }

            $wimArchitecture = ($wim | Out-String -Stream | Select-String Architecture | Out-String | ForEach-Object {$_ -replace '.*:', ''}).Trim()
            Write-Log "Win VM Arch found $wimArchitecture ..."

            if (($wimArchitecture -ne 'ARM') -and ($wimArchitecture -ne 'ARM64')) {
                if (Test-Path "$($systemDrive)\boot\bcd") {
                    Write-Log 'Image already has BIOS BCD store...'
                }
                elseif (Test-Path "$($systemDrive)\efi\microsoft\boot\bcd") {
                    Write-Log 'Image already has EFI BCD store...'
                }
                else {
                    Write-Log 'Making image bootable...'
                    # Path to the \Windows on the VHD, Specifies the volume letter of the drive to create the \BOOT folder on.
                    $bcdBootArgs = @("$($windowsDrive)\Windows", "/s $systemDrive", '/v')

                    # Add firmware type option of the target system partition
                    switch ($DiskLayout) {
                        'BIOS' {
                            $bcdBootArgs += '/f BIOS'
                        }

                        'UEFI' {
                            $bcdBootArgs += '/f UEFI'
                        }

                        'WindowsToGo' {
                            if (Test-Path "$($windowsDrive)\Windows\boot\EFI\bootmgfw.efi") {
                                $bcdBootArgs += '/f ALL'
                            }
                        }
                    }

                    Run-Exe -Executable $BCDBoot -ExeArgs $bcdBootArgs

                    if ($DiskLayout -eq 'BIOS') {
                        Write-Log "Fixing the Device ID in the BCD store on $($VHDFormat)..."
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{bootmgr`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} osdevice locate")
                    }
                }

                Write-Log 'Drive is bootable. Cleaning up...'
            }
            else {
                Write-Log 'Image applied. Not bootable.'
            }

            # Remove system partition access path, if necessary
            if ($DiskLayout -eq 'UEFI') {
                $systemPartition | Remove-PartitionAccessPath -AccessPath $systemPartition.AccessPaths[0]
            }

            if ($hyperVEnabled) {
                Write-Log "Dismounting $VHDFormat..."
                Dismount-VHD -Path $VHDPath
            }
            else {
                Write-Log "Closing $VHDFormat..."
                Dismount-DiskImage -ImagePath $VHDPath
            }

            $vhdFinalPath = Join-Path (Split-Path $VHDPath -Parent) $vhdFinalName
            Write-Log "$VHDFormat final path is : $vhdFinalPath"

            if (Test-Path $vhdFinalPath) {
                Write-Log "Deleting pre-existing $VHDFormat : $(Split-Path $vhdFinalPath -Leaf)..."
                Remove-Item -Path $vhdFinalPath -Force
            }

            Write-Log "Renaming $VHDFormat at $VHDPath to $vhdFinalName"
            Rename-Item -Path (Resolve-Path $VHDPath).Path -NewName $vhdFinalName -Force
            $vhd += Get-DiskImage -ImagePath $vhdFinalPath

            $vhdFinalName = $null
        }
        catch {
            Write-Error $_
            Write-Log "Log folder is $logDir"
        }
        finally {
            # If VHD is mounted, unmount it
            if (Test-Path $VHDPath) {
                if ($hyperVEnabled) {
                    if ((Get-VHD -Path $VHDPath).Attached) {
                        Dismount-VHD -Path $VHDPath
                    }
                }
                else {
                    Dismount-DiskImage -ImagePath $VHDPath
                }
            }

            if ($null -ne $openIso) {
                Write-Log 'Closing ISO...'
                Dismount-DiskImage $isoFinalPath
            }

            if (-not $CacheSrc) {
                if ($tempSource -and (Test-Path $tempSource)) {
                    Remove-Item -Path $tempSource -Force
                }
            }

            Write-Log 'Done.'
        }
    }

    End {
        if ($Passthru) {
            return $vhd
        }
    }
}