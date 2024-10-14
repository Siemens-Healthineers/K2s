# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
	$module = "$PSScriptRoot\BaseImage.module.psm1"

	$moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Helpers' -Tag 'unit', 'ci', 'baseimage' {
	Describe 'Assert-IsoContentParameters' {
		BeforeAll {
			$wrongIPv4Values = @($null, '', '  ', 
				'256.100.100.100', '100.256.100.100', '100.100.256.100', '100.100.100.256',
				'100.101.102', 
				'a.101.102.103', '100.b.102.103', '100.101.c.103', '100.101.102.d',
				'-1.101.102.103', '100.-2.102.103', '100.101.-3.103', '100.101.102.-4')
		}
			
		BeforeEach {
			[Hashtable]$validParameters = @{
				Hostname             = 'myhostname'
				NetworkInterfaceName = 'myNetworkInterfaceName'
				IPAddressVM          = '172.30.31.32'
				IPAddressGateway     = '172.30.31.1'
				IPAddressDnsServers  = '167.3.2.1,8.8.8.8'
				UserName             = 'myUserName'
				UserPwd              = 'myUserPwd'                
			}
		}
		It 'with valid parameter object does not throw' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters } {
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Not -Throw 
			}
		}
		It 'with parameter object missing throws' {
			InModuleScope $moduleName {
				{ Assert-IsoContentParameters } | Should -Throw -ExpectedMessage 'Parameter missing: Parameter'
			}
		}
		It 'with invalid hostname throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters } {
				foreach ($value in @($null, '', '  ')) {
					$validParameters['Hostname'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is null, empty or contain only white spaces: Hostname'
				}
				$validParameters['Hostname'] = 'myHostnameContainingUppercaseLetters'
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument not valid: Hostname (only lowercase letters of the english alphabet are allowed)'
		
				$validParameters.Remove('Hostname')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: Hostname'
			}
		}
		It 'with invalid NetworkInterfaceName throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters } {
				foreach ($value in @($null, '', '  ')) {
					$validParameters['NetworkInterfaceName'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is null, empty or contain only white spaces: NetworkInterfaceName'
				}
					
				$validParameters.Remove('NetworkInterfaceName')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: NetworkInterfaceName'
			}
		}
		It 'with invalid IPAddressVM throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters; wrongIPv4Values = $wrongIPv4Values } {
				foreach ($value in $wrongIPv4Values) {
					$validParameters['IPAddressVM'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is not valid IPv4: IPAddressVM'
				}
					
				$validParameters.Remove('IPAddressVM')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: IPAddressVM'
			}
		}
		It 'with invalid IPAddressGateway throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters; wrongIPv4Values = $wrongIPv4Values } {
				foreach ($value in $wrongIPv4Values) {
					$validParameters['IPAddressGateway'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is not valid IPv4: IPAddressGateway'
				}
					
				$validParameters.Remove('IPAddressGateway')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: IPAddressGateway'
			}
		}
		It 'with invalid IPAddressDnsServers throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters; wrongIPv4Values = $wrongIPv4Values } {
				$expectedMessage = 'Argument does not contain a valid IPv4: IPAddressDnsServers (only a comma separated list of IPv4 addresses is allowed)'
				foreach ($value in $wrongIPv4Values) {
					$validParameters['IPAddressDnsServers'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage $expectedMessage
		
					$validParameters['IPAddressDnsServers'] = "100.101.102.103,$value"
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage $expectedMessage
				}  
		
				$validParameters.Remove('IPAddressDnsServers')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: IPAddressDnsServers'
			}
		}
		It 'with invalid UserName throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters } {
				foreach ($value in @($null, '', '  ')) {
					$validParameters['UserName'] = $value
					{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is null, empty or contain only white spaces: UserName'
				}
		
				$validParameters.Remove('UserName')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: UserName'
			}
		}
		It 'with invalid UserPwd throws' {
			InModuleScope $moduleName -Parameters @{ validParameters = $validParameters } {
				$validParameters['UserPwd'] = $null
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Argument is null: UserPwd'
		
				$validParameters.Remove('UserPwd')
				{ Assert-IsoContentParameters -Parameter $validParameters } | Should -Throw -ExpectedMessage 'Missing key: UserPwd'
			}
		}
	}
	
	Describe 'Convert-Text' -Tag 'unit', 'ci', 'baseimage' {
		It 'with missing arguments throws' {
			InModuleScope $moduleName {
				{ Convert-Text -Source '' } | Get-ExceptionMessage | Should -BeLike 'Argument missing: ConversionTable'
				{ Convert-Text -ConversionTable @{} } | Get-ExceptionMessage | Should -BeLike 'Argument missing: Source'
			}
		}
		It 'converts and returns the converted text' {
			InModuleScope $moduleName {
				$conversionTable = @{'__SearchPattern1__' = 'convertedText1'; '__SearchPattern2__' = 'convertedText2' }
				$inputText = "This is a multiline sample text containing the following: __SearchPattern1__ and `n also __SearchPattern2__"
				$expectedOutputText = "This is a multiline sample text containing the following: $($conversionTable['__SearchPattern1__']) and `n also $($conversionTable['__SearchPattern2__'])"
	
				$actualOutput = Convert-Text -Source $inputText -ConversionTable $conversionTable
	
				$actualOutput | Should -Be $expectedOutputText
			}
		}
	}
	
	Describe 'Invoke-ScriptFile' {
		It 'with missing arguments throws' {
			InModuleScope $moduleName {
				{ Invoke-ScriptFile -Params @{} } | Get-ExceptionMessage | Should -BeLike 'Argument missing: ScriptPath'
			}
		}
	}
	
	Describe 'Invoke-Tool' {
		It 'with missing arguments throws' {
			InModuleScope $moduleName {
				{ Invoke-Tool -Arguments '' } | Get-ExceptionMessage | Should -BeLike 'Argument missing: ToolPath'
			}
		}
		It 'delegates call to Start-Process' {
			InModuleScope $moduleName {
				Mock Start-Process { $global:LASTEXITCODE = 0; 'mock process started' }
				$path = 'my path'
				$arguments = 'my arguments'
	
				Invoke-Tool -ToolPath $path -Arguments $arguments
	
				Should -Invoke -CommandName Start-Process -Times 1 -ParameterFilter { $FilePath -eq $path -and $ArgumentList -eq $arguments -and $WindowStyle -eq 'Hidden' -and $Wait -eq $true }
			}
		}
		It 'with LASTEXITCODE != 0 throws' {
			InModuleScope $moduleName {
				$exitCodeValue = 1
				Mock Start-Process { $global:LASTEXITCODE = $exitCodeValue; 'mock process started' }
				Mock Write-Log {}
				$path = 'my path'
	
				{ Invoke-Tool -ToolPath $path -Arguments 'my arguments' } | Get-ExceptionMessage | Should -Be "Tool '$path' returned code '$exitCodeValue'."
				$exitCodeValue = -1
				{ Invoke-Tool -ToolPath $path -Arguments 'my arguments' } | Get-ExceptionMessage | Should -Be "Tool '$path' returned code '$exitCodeValue'."
			}
		}
	}
	
	Describe 'New-Folder' {
		It 'validates parameter' {
			InModuleScope $moduleName {
				Mock Assert-LegalCharactersInPath { return $false }
				$path = 'my path'
	
				{ New-Folder -Path $path } | Get-ExceptionMessage | Should -BeLike "*Cannot validate argument on parameter 'Path'*"
	
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $path }
			}
		}
		It 'folder exists? <Exists> --> create? <ExpectedIsCreated>' -ForEach @(
			@{ Exists = $true; ExpectedIsCreated = $false }
			@{ Exists = $false; ExpectedIsCreated = $true }
		) {
			InModuleScope $moduleName -Parameters @{Exists = $Exists; ExpectedIsCreated = $ExpectedIsCreated } {
				$pathToCreate = 'any path value'
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Test-Path { return $Exists } -ParameterFilter { $Path -eq $pathToCreate }
				Mock New-Item {} 
	
				$output = New-Folder -Path $pathToCreate
	
				Should -Invoke -CommandName Test-Path -Times 1 -ParameterFilter { $Path -eq $pathToCreate -and $ErrorAction -eq 'Stop' }
				Should -Invoke -CommandName Test-Path -Times 0 -ParameterFilter { $Path -ne $pathToCreate }
	
				if ($ExpectedIsCreated) {
					Should -Invoke -CommandName New-Item -Times 1
					Should -Invoke -CommandName New-Item -Times 1 -ParameterFilter { $Path -eq $pathToCreate -and $ItemType -eq 'Directory' -and $ErrorAction -eq 'Stop' }
				}
				else {
					Should -Invoke -CommandName New-Item -Times 0
				}
				$output.Path | Should -Be $pathToCreate
				$output.Existed | Should -Be $(!$ExpectedIsCreated)
			}
		}
		It 'gets path value from pipeline by value' {
			InModuleScope $moduleName {
				$pathToCreate = 'any path value'
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Test-Path { return $False }
				Mock New-Item {} 
	
				$output = $pathToCreate | New-Folder
	
				$output.Path | Should -Be $pathToCreate
			}
		}
	}
	
	Describe 'Remove-FolderContent' {
		It 'validates parameter' {
			InModuleScope $moduleName {
				Mock Assert-LegalCharactersInPath { return $false }
				$path = 'my path'
	
				{ Remove-FolderContent -Path $path } | Get-ExceptionMessage | Should -BeLike "*Cannot validate argument on parameter 'Path'*"
	
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $path }
			}
		}
		It 'folder is emptied' {
			InModuleScope $moduleName {
				$pathToDelete = 'any path value'
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Test-Path { return $true } -ParameterFilter { $Path -eq $pathToDelete }
				Mock Remove-Item {} 
	
				$output = Remove-FolderContent -Path $pathToDelete
	
				Should -Invoke -CommandName Test-Path -Times 1 -ParameterFilter { $Path -eq $pathToDelete -and $ErrorAction -eq 'Stop' }
				Should -Invoke -CommandName Test-Path -Times 0 -ParameterFilter { $Path -ne $pathToDelete }
				Should -Invoke -CommandName Remove-Item -Times 1
				Should -Invoke -CommandName Remove-Item -Times 1 -ParameterFilter { $Path -eq $pathToDelete -and $Recurse -eq $true -and $Force -eq $true -and $ErrorAction -eq 'Stop' }
				$output | Should -Be $pathToDelete
			}
		}
		It 'gets path value from pipeline by value' {
			InModuleScope $moduleName {
				$pathToDelete = 'any path value'
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Test-Path { return $true }
				Mock Remove-Item {} 
	
				$output = $pathToDelete | Remove-FolderContent
	
				$output | Should -Be $pathToDelete
			}
		}
		It 'with not existing folder throws' {
			InModuleScope $moduleName {
				$pathToDelete = 'any path value'
				Mock Test-Path { return $false } -ParameterFilter { $Path -eq $pathToDelete }
	
				{ Remove-FolderContent -Path $pathToDelete } | Get-ExceptionMessage | Should -BeLike "*The Path '$pathToDelete' does not exist*"
			}
		}
	}
	
	Describe 'Copy-VhdxFile' {
		It 'validates arguments and performs copy' {
			InModuleScope $moduleName {
				$sourceFilePath = 'myFile.vhdx'
				$targetPath = 'myFolder\myTargetFile.vhdx'
				$parentFolder = 'myFolder'
	
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-Pattern { return $true } 
				Mock Assert-Path { } 
				Mock Copy-Item { } 
				Mock Copy-Item { } 
				Mock Split-Path { $parentFolder }
				
				Copy-VhdxFile -SourceFilePath $sourceFilePath -TargetPath $targetPath
		
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 2
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $sourceFilePath } 
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $targetPath } 
				Should -Invoke -CommandName Assert-Pattern -Times 1 -ParameterFilter { $Path -eq $sourceFilePath -and $Pattern -eq '.*\.vhdx$' }
				Should -Invoke -CommandName Assert-Pattern -Times 1 -ParameterFilter { $Path -eq $targetPath -and $Pattern -eq '.*\.vhdx$' }
				Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $sourceFilePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
				Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $targetPath -and $PathType -eq 'Leaf' -and $ShallExist -eq $false }
				Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq "$parentFolder" -and $PathType -eq 'Container' -and $ShallExist -eq $true }
		
				Should -Invoke -CommandName Copy-Item -Times 1 -ParameterFilter { $Path -eq "$sourceFilePath" -and $Destination -eq "$targetPath" -and $Force -eq $true -and $ErrorAction -eq 'Stop' }
			}		
		}
	}
}

Describe 'New-VhdxDebianCloud' -Tag 'unit', 'ci', 'baseimage' {
	It "using proxy '<ProxyValue>'" -ForEach @(
		@{ ProxyValue = '' }
		@{ ProxyValue = 'a particular proxy' }
		@{ ProxyValue = 'the default one' }
	) {
		InModuleScope $moduleName -Parameters @{ProxyValue = $ProxyValue } {
			$expectedTargetFilePath = 'target file path'
			$parentOfTargetFilePath = 'parent of target file path'
			$expectedDownloadsDirectory = 'downloads directory'
			$expectedDebianImage = 'debian image'
			$expectedQemuTool = 'qemu tool'
			$expectedVhdxFile = 'vhdx file'
			Mock Assert-LegalCharactersInPath { return $true }
			Mock Assert-Path { '' }
			Mock Assert-Path { $expectedDebianImage } -ParameterFilter { $Path -eq $expectedDebianImage }
			Mock Assert-Path { $expectedQemuTool } -ParameterFilter { $Path -eq $expectedQemuTool }
			Mock Split-Path { return $parentOfTargetFilePath }
			Mock Get-DebianImage { return $expectedDebianImage }
			Mock Get-QemuTool { return $expectedQemuTool }
			Mock New-VhdxFile { return $expectedVhdxFile }

			if ($ProxyValue -eq 'the default one') {
				$ExpectedProxy = ''
				New-VhdxDebianCloud -TargetFilePath $expectedTargetFilePath -DownloadsDirectory $expectedDownloadsDirectory
			}
			else {
				$ExpectedProxy = $ProxyValue
				New-VhdxDebianCloud -TargetFilePath $expectedTargetFilePath -DownloadsDirectory $expectedDownloadsDirectory -Proxy $ExpectedProxy				
			}

			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedTargetFilePath }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedTargetFilePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $false }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $parentOfTargetFilePath -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory -and $PathType -eq 'Container' -and $ShallExist -eq $true }

			Should -Invoke -CommandName Get-DebianImage -Times 1 -ParameterFilter { $Proxy -eq $ExpectedProxy -and $DownloadsDirectory -eq $expectedDownloadsDirectory }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedDebianImage -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Get-QemuTool -Times 1 -ParameterFilter { $Proxy -eq $ExpectedProxy -and $DownloadsDirectory -eq $expectedDownloadsDirectory }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedQemuTool -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName New-VhdxFile -Times 1 -ParameterFilter { $SourcePath -eq $expectedDebianImage -and $VhdxPath -eq $expectedTargetFilePath -and $QemuExePath -eq $expectedQemuTool }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedVhdxFile -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
		}
	}
}

Describe 'Get-DebianImage' -Tag 'unit', 'ci', 'baseimage' {
	It "using proxy '<ProxyValue>'" -ForEach @(
		@{ ProxyValue = '' }
		@{ ProxyValue = 'a particular proxy' }
		@{ ProxyValue = 'the default one' }
	) {
		InModuleScope $moduleName -Parameters @{ProxyValue = $ProxyValue } {
			$expectedDownloadsDirectory = 'downloads directory'
			$expectedDebianImageFile = 'debian image file'
			Mock Assert-LegalCharactersInPath { return $true }
			Mock Assert-Path { 'path asserted' }
			Mock Invoke-ScriptFile { $expectedDebianImageFile }
			$installationPath = 'installationPath'
			$global:KubernetesPath = $installationPath

			if ($ProxyValue -eq 'the default one') {
				$ExpectedProxy = ''
				$output = Get-DebianImage -DownloadsDirectory $expectedDownloadsDirectory 
			}
			else {
				$ExpectedProxy = $ProxyValue
				$output = Get-DebianImage -DownloadsDirectory $expectedDownloadsDirectory -Proxy $ExpectedProxy				
			}
			
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Invoke-ScriptFile -Times 1 -ParameterFilter { $ScriptPath -like '*\..\common\vmtools\Get-DebianImage.ps1' -and $Params['OutputPath'] -eq $expectedDownloadsDirectory -and $Params['Proxy'] -eq $ExpectedProxy }
			$output | Should -Be $expectedDebianImageFile
		}
	}
}

Describe 'Get-QemuTool' -Tag 'unit', 'ci', 'baseimage' {
	It "using proxy '<ProxyValue>'" -ForEach @(
		@{ ProxyValue = '' }
		@{ ProxyValue = 'a particular proxy' }
		@{ ProxyValue = 'the default one' }
	) {
		InModuleScope $moduleName -Parameters @{ProxyValue = $ProxyValue } {
			$expectedDownloadsDirectory = 'downloads directory'
			$expectedQemuExecutable = 'qemu executable'
			Mock Assert-LegalCharactersInPath { return $true }
			Mock Assert-Path { 'path asserted' }
			Mock Get-QemuExecutable { $expectedQemuExecutable }

			if ($ProxyValue -eq 'the default one') {
				$ExpectedProxy = ''
				$output = Get-QemuTool -DownloadsDirectory $expectedDownloadsDirectory 
			}
			else {
				$ExpectedProxy = $ProxyValue
				$output = Get-QemuTool -DownloadsDirectory $expectedDownloadsDirectory -Proxy $ExpectedProxy				
			}

			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedDownloadsDirectory -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Get-QemuExecutable -Times 1 -ParameterFilter { $Proxy -eq $ExpectedProxy -and $OutputDirectory -eq $expectedDownloadsDirectory }
			$output | Should -Be $expectedQemuExecutable
		}
	}
}


Describe 'New-VhdxFile' -Tag 'unit', 'ci', 'baseimage' {
	It 'invokes tool to create vhdx' {
		InModuleScope $moduleName {
			$expectedSourcePath = 'the source path'
			$expectedVhdxPath = 'the vhdx path'
			$expectedQemuExePath = 'the qemu exe path'
			$expectedParentOfVhdxPath = 'the parent of the vhdx path'

			Mock Assert-LegalCharactersInPath { $true }
			Mock Assert-Path { 'path asserted' }
			Mock Split-Path { $expectedParentOfVhdxPath }
			Mock Invoke-Tool { 
				Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedVhdxPath -and $PathType -eq 'Leaf' -and $ShallExist -eq $false }
			}

			$output = New-VhdxFile -SourcePath $expectedSourcePath -VhdxPath $expectedVhdxPath -QemuExePath $expectedQemuExePath

			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedSourcePath }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedVhdxPath }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedQemuExePath }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedSourcePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedParentOfVhdxPath -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedQemuExePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Invoke-Tool -Times 1 -ParameterFilter { $ToolPath -eq $expectedQemuExePath -and $Arguments -eq "convert -f qcow2 `"$expectedSourcePath`" -O vhdx -o subformat=dynamic `"$expectedVhdxPath`"" }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedVhdxPath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			$output | Should -Be $expectedVhdxPath
		}
	}
}

Describe 'New-IsoFile' -Tag 'unit', 'ci', 'baseimage' {
	It 'invokes tool to create iso' {
		InModuleScope $moduleName {
			$expectedIsoFileCreatorToolPath = 'the iso file creator tool path'
			$expectedIsoFilePath = 'the iso file path'
			$expectedSourcePath = 'the source path'
			$expectedIsoContentParameterValue = @{
				Hostname             = 'myhostname'
				NetworkInterfaceName = 'myNetworkInterfaceName'
				IPAddressVM          = '172.30.31.32'
				IPAddressGateway     = '172.30.31.1'
				IPAddressDnsServers  = '167.3.2.1,8.8.8.8'
				UserName             = 'myUserName'
				UserPwd              = 'myUserPwd'
			}     
			$expectedParentOfIsoFilePath = 'the parent of the iso file path'
			$expectedCloudDataTargetDirectory = "$expectedParentOfIsoFilePath\cloud-data"
			$expectedMetaDataTemplateSourceFile = "$expectedSourcePath\meta-data"
			$expectedNetworkConfigTemplateSourceFile = "$expectedSourcePath\network-config"
			$expectedUserDataTemplateSourceFile = "$expectedSourcePath\user-data"
			$expectedGuid = '0af84903-9174-4b77-8382-881f6c165708'
			$metaDataFileContent = 'metaDataFileContent'
			$expectedConvertedMetaDataFileContent = 'convertedMetaDataFileContent'
			$expectedMetaDataConversionTable = @{
				'__INSTANCE_NAME__'        = $expectedGuid
				'__LOCAL-HOSTNAME_VALUE__' = $expectedIsoContentParameterValue.Hostname
			}
			$networkConfigFileContent = 'networkConfigFileContent'
			$expectedConvertedNetworkConfigFileContent = 'convertedNetworkConfigFileContent'
			$expectedNetworkConfigConversionTable = @{
				'__NETWORK_INTERFACE_NAME__'   = $expectedIsoContentParameterValue.NetworkInterfaceName
				'__IP_ADDRESS_VM__'            = $expectedIsoContentParameterValue.IPAddressVM
				'__IP_ADDRESS_GATEWAY__'       = $expectedIsoContentParameterValue.IPAddressGateway
				'__IP_ADDRESSES_DNS_SERVERS__' = $expectedIsoContentParameterValue.IPAddressDnsServers
			}
			$userDataFileContent = 'userDataFileContent'
			$expectedConvertedUserDataFileContent = 'convertedUserDataFileContent'
			$expectedUserDataConversionTable = @{
				'__LOCAL-HOSTNAME_VALUE__'     = $expectedIsoContentParameterValue.Hostname
				'__VM_USER__'                  = $expectedIsoContentParameterValue.UserName
				'__VM_USER_PWD__'              = $expectedIsoContentParameterValue.UserPwd
				'__IP_ADDRESSES_DNS_SERVERS__' = ($expectedIsoContentParameterValue.IPAddressDnsServers -replace ',', '\n nameserver ')
			}
			Mock Assert-LegalCharactersInPath { $true }
			Mock Assert-Pattern { $true }
			Mock Assert-Path { 'path asserted' }
			Mock Split-Path { $expectedParentOfIsoFilePath }
			Mock New-Item { 'the new item' }
			Mock Get-Content { return $metaDataFileContent } -ParameterFilter { $Path -eq $expectedMetaDataTemplateSourceFile -and $Raw -eq $true -and $ErrorAction -eq 'Stop' }
			Mock Get-Content { return $networkConfigFileContent } -ParameterFilter { $Path -eq $expectedNetworkConfigTemplateSourceFile -and $Raw -eq $true -and $ErrorAction -eq 'Stop' }
			Mock Get-Content { return $userDataFileContent } -ParameterFilter { $Path -eq $expectedUserDataTemplateSourceFile -and $Raw -eq $true -and $ErrorAction -eq 'Stop' }
			Mock Convert-Text { return $expectedConvertedMetaDataFileContent } -ParameterFilter { $Source -eq $metaDataFileContent -and (Compare-Hashtables $ConversionTable $expectedMetaDataConversionTable) }
			Mock Convert-Text { return $expectedConvertedNetworkConfigFileContent } -ParameterFilter { $Source -eq $networkConfigFileContent -and (Compare-Hashtables $ConversionTable $expectedNetworkConfigConversionTable) }
			Mock Convert-Text { return $expectedConvertedUserDataFileContent } -ParameterFilter { $Source -eq $userDataFileContent -and (Compare-Hashtables $ConversionTable $expectedUserDataConversionTable ) }
			Mock New-Guid { @{ Guid = $expectedGuid } } 
			Mock Set-Content { }
			Mock Invoke-Tool {}

			$output = New-IsoFile -IsoFileCreatorToolPath $expectedIsoFileCreatorToolPath -IsoFilePath $expectedIsoFilePath -SourcePath $expectedSourcePath -IsoContentParameterValue $expectedIsoContentParameterValue

			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedIsoFileCreatorToolPath }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedIsoFilePath }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedSourcePath }
			Should -Invoke -CommandName Assert-Pattern -Times 1 -ParameterFilter { $Path -eq $expectedIsoFilePath -and $Pattern -eq '^.*\.iso$' }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedIsoFileCreatorToolPath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedIsoFilePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $false }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedParentOfIsoFilePath -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedSourcePath -and $PathType -eq 'Container' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedCloudDataTargetDirectory -and $PathType -eq 'Container' -and $ShallExist -eq $false }
			Should -Invoke -CommandName New-Item -Times 1 -ParameterFilter { $Path -eq $expectedCloudDataTargetDirectory -and $ItemType -eq 'Directory' -and $Force -eq $true -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedMetaDataTemplateSourceFile -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedNetworkConfigTemplateSourceFile -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedUserDataTemplateSourceFile -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName Set-Content -Times 1 -ParameterFilter { $Path -eq "$expectedCloudDataTargetDirectory\meta-data" -and $Value -eq $expectedConvertedMetaDataFileContent -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Set-Content -Times 1 -ParameterFilter { $Path -eq "$expectedCloudDataTargetDirectory\network-config" -and $Value -eq $expectedConvertedNetworkConfigFileContent -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Set-Content -Times 1 -ParameterFilter { $Path -eq "$expectedCloudDataTargetDirectory\user-data" -and $Value -eq $expectedConvertedUserDataFileContent -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Invoke-Tool -Times 1 -ParameterFilter { $ToolPath -eq $expectedIsoFileCreatorToolPath -and $Arguments -eq "-sourceDir `"$expectedCloudDataTargetDirectory`" -targetFilePath `"$expectedIsoFilePath`"" }
			$output | Should -Be $expectedIsoFilePath
		}
	}
}




Describe 'New-VirtualMachineForBaseImageProvisioning' -Tag 'unit', 'ci', 'baseimage' {
	Context 'arguments validation' {
		BeforeEach {
			$paramsTemplate = @{'VmName' = 'myVmName'
				'VhdxFilePath'              = 'Z:\myFolder\myFile.vhdx'
				'IsoFilePath'               = 'Z:\myFolder\myIsoFile.iso'
				'VMMemoryStartupBytes'      = 12
				'VMProcessorCount'          = 4
				'VMDiskSize'                = 10
			}
		}
		It "VM name '<Name>'" -ForEach @(
			@{ Name = $null }
			@{ Name = '' }
			@{ Name = '  ' }
		) {
			InModuleScope $moduleName -Parameters @{Name = $Name; Params = $paramsTemplate } {
				$Params['VmName'] = $Name
				{ New-VirtualMachineForBaseImageProvisioning @params } | Get-ExceptionMessage | Should -BeLike '*VmName*'
			}
		}
		It 'VhdxFilePath' {
			InModuleScope $moduleName -Parameters @{ Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $false }
				Mock Assert-Pattern { return $true } 
	
				{ New-VirtualMachineForBaseImageProvisioning @Params } | Get-ExceptionMessage | Should -BeLike '*VhdxFilePath*' 

				$expectedVhdxFilePath = $Params.VhdxFilePath
				Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1 -ParameterFilter { $Path -eq $expectedVhdxFilePath } 
				Should -Invoke -CommandName Assert-Pattern -Times 1 -ParameterFilter { $Path -eq $expectedVhdxFilePath -and $Pattern -eq '^.*\.vhdx$' }
			}
		}
		It 'IsoFilePath legal characters' {
			InModuleScope $moduleName -Parameters @{Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-LegalCharactersInPath { return $false } -ParameterFilter { $Path -eq $Params.IsoFilePath }
            
				{ New-VirtualMachineForBaseImageProvisioning @params } | Get-ExceptionMessage | Should -Be "The file $($Params.IsoFilePath) contains illegal characters"
			}
		}
		It 'IsoFilePath wrong pattern' {
			InModuleScope $moduleName -Parameters @{Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-Pattern { return $false } -ParameterFilter { $Path -eq $Params.IsoFilePath -and $Pattern -eq '^.*\.iso$' }
            
				{ New-VirtualMachineForBaseImageProvisioning @params } | Get-ExceptionMessage | Should -Be "The file $($Params.IsoFilePath) does not match the pattern '*.iso'"
			}
		}
		It 'VMMemoryStartupBytes' -ForEach @(
			@{ Value = 0 }
			@{ Value = -1 }
		) {
			InModuleScope $moduleName -Parameters @{ Value = $Value; Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-Pattern { return $true } 
				$Params['VMMemoryStartupBytes'] = $Value

				{ New-VirtualMachineForBaseImageProvisioning @Params } | Get-ExceptionMessage | Should -BeLike '*VMMemoryStartupBytes*' 
			}
		}
		It 'VMProcessorCount=<Value>' -ForEach @(
			@{ Value = 0 }
			@{ Value = -1 }
		) {
			InModuleScope $moduleName -Parameters @{ Value = $Value; Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-Pattern { return $true } 
				$Params['VMProcessorCount'] = $Value

				{ New-VirtualMachineForBaseImageProvisioning @Params } | Get-ExceptionMessage | Should -BeLike '*VMProcessorCount*' 
			}
		}
		It 'VMDiskSize=<Value>' -ForEach @(
			@{ Value = 0 }
			@{ Value = -1 }
		) {
			InModuleScope $moduleName -Parameters @{ Value = $Value; Params = $paramsTemplate } {
				Mock Assert-LegalCharactersInPath { return $true }
				Mock Assert-Pattern { return $true } 
				$Params['VMDiskSize'] = $Value

				{ New-VirtualMachineForBaseImageProvisioning @Params } | Get-ExceptionMessage | Should -BeLike '*VMDiskSize*' 
			}
		}
	}
	It "creates virtual machine using iso file '<WithIsoFile>'" -ForEach @(
		@{ WithIsoFile = '' }
		@{ WithIsoFile = '   ' }
		@{ WithIsoFile = 'theIsoFile.iso' }
	) {
		InModuleScope $moduleName -Parameters @{ WithIsoFile = $WithIsoFile } {
			$expectedVmName = 'myVmName'
			$expectedVhdxFilePath = 'Z:\myFolder\myFile.vhdx'
			$expectedIsoFilePath = $WithIsoFile
			$expectedStartupBytes = 12
			$expectedProcessorCount = 4
			$expectedDiskSize = 10

			Mock Assert-LegalCharactersInPath { return $true }
			Mock Assert-Pattern { return $true } 
			Mock Assert-Path { } 
			Mock New-VM { } 
			Mock Set-VMMemory { } 
			Mock Set-VMProcessor { } 
			Mock Set-VMDvdDrive { } 
			Mock Resize-VHD { } 
			Mock Write-Log { }

			$params = @{'VmName'    = $expectedVmName
				'VhdxFilePath'         = $expectedVhdxFilePath
				'IsoFilePath'          = $expectedIsoFilePath
				'VMMemoryStartupBytes' = $expectedStartupBytes
				'VMProcessorCount'     = $expectedProcessorCount
				'VMDiskSize'           = $expectedDiskSize
			}
			New-VirtualMachineForBaseImageProvisioning @params

			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedVhdxFilePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			Should -Invoke -CommandName New-VM -Times 1 -ParameterFilter { $Name -eq "$expectedVmName" -and $VhdPath -eq "$expectedVhdxFilePath" -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Set-VMMemory -Times 1 -ParameterFilter { $VMName -eq "$expectedVmName" -and $DynamicMemoryEnabled -eq $false -and $StartupBytes -eq "$expectedStartupBytes" -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Set-VMProcessor -Times 1 -ParameterFilter { $VMName -eq "$expectedVmName" -and $Count -eq $expectedProcessorCount -and $ErrorAction -eq 'Stop' }
			Should -Invoke -CommandName Resize-VHD -Times 1 -ParameterFilter { $Path -eq "$expectedVhdxFilePath" -and $SizeBytes -eq $expectedDiskSize -and $ErrorAction -eq 'Stop' }

			if (![string]::IsNullOrWhiteSpace($expectedIsoFilePath)) {
				Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedIsoFilePath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
				Should -Invoke -CommandName Set-VMDvdDrive -Times 1 -ParameterFilter { $VMName -eq "$expectedVmName" -and $Path -eq $expectedIsoFilePath -and $ErrorAction -eq 'Stop' }
			}
			else {
				Should -Invoke -CommandName Set-VMDvdDrive -Times 0
			}
		}
	}
}

Describe 'Remove-VirtualMachineForBaseImageProvisioning' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Remove-VirtualMachineForBaseImageProvisioning -VmName $InvalidValue -VhdxFilePath 'a file' } | Get-ExceptionMessage | Should -BeLike '*VmName*'
					{ Remove-VirtualMachineForBaseImageProvisioning -VmName 'the name' -VhdxFilePath $InvalidValue } | Get-ExceptionMessage | Should -BeLike '*VhdxFilePath*'
					{ Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath 'a file' } | Get-ExceptionMessage | Should -BeLike '*VmName*'
					{ Remove-VirtualMachineForBaseImageProvisioning -VmName 'the name' } | Get-ExceptionMessage | Should -BeLike '*VhdxFilePath*'
				}
			}
		}
	}
	It 'Removes virtual machine if existing (<VmExists>) and removes vhdx file if existing (<VhdxFileExists>)' -ForEach @(
		@{ VmExists = $true; VhdxFileExists = $true }
		@{ VmExists = $true; VhdxFileExists = $false }
		@{ VmExists = $false; VhdxFileExists = $true }
		@{ VmExists = $false; VhdxFileExists = $false }
	) {
		InModuleScope $moduleName -Parameters @{ VmExists = $VmExists; VhdxFileExists = $VhdxFileExists } {
			$expectedVmName = 'the VM name'
			$expectedVhdxFilePath = 'the vhdx file path'

			Mock Write-Log { }
			Mock Test-Path { $VhdxFileExists }
			Mock Disconnect-VmFromSwitch { }
			Mock Remove-VM
			Mock Remove-Item
			Mock Get-VM {
				if ($VmExists) {
					[PSCustomObject]@{
						Name = $expectedVmName
					}
				}
				else {
					[PSCustomObject]@{
						Name = 'other name'
					}
				}
			}

			Remove-VirtualMachineForBaseImageProvisioning -VmName $expectedVmName -VhdxFilePath $expectedVhdxFilePath

			if ($VmExists) {
				$expectedRemoveVMCalledTimes = 1
			}
			else {
				$expectedRemoveVMCalledTimes = 0
			}
			if ($VhdxFileExists) {
				$expectedRemoveItemCalledTimes = 1
			}
			else {
				$expectedRemoveItemCalledTimes = 0
			}
			Should -Invoke -CommandName Remove-VM -Times $expectedRemoveVMCalledTimes -ParameterFilter { $Name -eq $expectedVmName -and $Force -eq $true }
			Should -Invoke -CommandName Remove-Item -Times $expectedRemoveItemCalledTimes -ParameterFilter { $Path -eq $expectedVhdxFilePath -and $Force -eq $true }
		}
	}
}

Describe 'Connect-VmToSwitch' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Connect-VmToSwitch -VmName $InvalidValue -SwitchName 'a switch name' } | Get-ExceptionMessage | Should -BeLike '*VmName*'
					{ Connect-VmToSwitch -VmName 'the vm name' -SwitchName $InvalidValue } | Get-ExceptionMessage | Should -BeLike '*SwitchName*'
					{ Connect-VmToSwitch -SwitchName 'a switch name' } | Get-ExceptionMessage | Should -BeLike '*VmName*'
					{ Connect-VmToSwitch -VmName 'the vm name' } | Get-ExceptionMessage | Should -BeLike '*SwitchName*'
				}
			}
		}
	}
	It 'performs connection' {
		InModuleScope $moduleName {
			$expectedVmName = 'the VM name'
			$expectedSwitchName = 'the switch name'
			Mock Connect-VMNetworkAdapter {}
			Mock Write-Log {}

			Connect-VmToSwitch -VmName $expectedVmName -SwitchName $expectedSwitchName

			Should -Invoke -CommandName Connect-VMNetworkAdapter -ParameterFilter { $VmName -eq $expectedVmName -and $SwitchName -eq $expectedSwitchName -and $ErrorAction -eq 'Stop' }
		}
	}

}

Describe 'Disconnect-VmFromSwitch' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Disconnect-VmFromSwitch -VmName $InvalidValue } | Get-ExceptionMessage | Should -BeLike '*VmName*'
					{ Disconnect-VmFromSwitch } | Get-ExceptionMessage | Should -BeLike '*VmName*'
				}
			}
		}
	}
	It 'performs disconnection' -ForEach @(
		@{ VmExists = $true }
		@{ VmExists = $false }
	) {
		InModuleScope $moduleName -Parameters @{ VmExists = $VmExists } {
			$expectedVmName = 'the VM name'
			Mock Write-Log {}
			Mock Disconnect-VMNetworkAdapter { }
			Mock Get-VM {
				if ($VmExists) {
					[PSCustomObject]@{
						Name   = $expectedVmName
						VmName = $expectedVmName
					}
				}
				else {
					[PSCustomObject]@{
						Name   = 'other name'
						VmName = 'other name'
					}
				}
			}
			if ($VmExists) {
				$expectedDisconnectMethodCalledTimes = 1
			}
			else {
				$expectedDisconnectMethodCalledTimes = 0
			}

			Disconnect-VmFromSwitch -VmName $expectedVmName
			
			Should -Invoke -CommandName Disconnect-VMNetworkAdapter -Times $expectedDisconnectMethodCalledTimes -ParameterFilter { $VmName -eq $expectedVmName -and $ErrorAction -eq 'Stop' }
		}
	}
}

Describe 'Start-VirtualMachineAndWaitForHeartbeat' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Start-VirtualMachineAndWaitForHeartbeat -Name $InvalidValue } | Get-ExceptionMessage | Should -BeLike '*Name*'
					{ Start-VirtualMachineAndWaitForHeartbeat } | Get-ExceptionMessage | Should -BeLike '*Name*'
				}
			}
		}
	}
	It 'performs start and wait' {
		InModuleScope $moduleName {
			Mock Start-VM { }
			Mock Wait-VM { }
			Mock Write-Log { }
			$expectedVmName = 'my name'
			
			Start-VirtualMachineAndWaitForHeartbeat -Name $expectedVmName

			Should -Invoke -CommandName Start-VM -ParameterFilter { $Name -eq $expectedVmName }
			Should -Invoke -CommandName Wait-VM -Times 2 -ParameterFilter { $Name -eq $expectedVmName -and $For -eq 'Heartbeat' }
		}
	}
}

Describe 'Stop-VirtualMachineForBaseImageProvisioning' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Stop-VirtualMachineForBaseImageProvisioning -Name $InvalidValue } | Get-ExceptionMessage | Should -BeLike '*Name*'
					{ Stop-VirtualMachineForBaseImageProvisioning } | Get-ExceptionMessage | Should -BeLike '*Name*'
				}
			}
		}
	}
	It 'performs stop (Vm exists: <VmExists>  Vm state: <VmState>)' -ForEach @(
		@{ VmExists = $true; VmState = 'Off' }
		@{ VmExists = $true; VmState = "state value is other than 'off'" }
		@{ VmExists = $false; VmState = 'value not used because VM does not exist' }
	) {
		InModuleScope $moduleName -Parameters @{ VmExists = $VmExists; VmState = $VmState } {
			$expectedVmName = 'my VM name'
			Mock Get-VM { 
				if ($VmExists) {
					@{ State = $VmState }
				}
				else {
					$null
				}
			}
			Mock Stop-VM { }
			Mock Get-VMHardDiskDrive { 
				@{ Path = '' }
			}
			Mock Write-Log {}

			Stop-VirtualMachineForBaseImageProvisioning -Name $expectedVmName

			if ($VmExists -and $VmState -ne 'Off') {
				Should -Invoke -CommandName Stop-VM -Times 1 -ParameterFilter { $Name -eq $expectedVmName }

			}
			else {
				Should -Invoke -CommandName Stop-VM -Times 0
			}
		}
	}
	It 'retries stop (avhdx file exists: <avhdxFileExists>)' -ForEach @(
		@{ avhdxFileExists = $true }
		@{ avhdxFileExists = $false }
	) {
		InModuleScope $moduleName -Parameters @{ avhdxFileExists = $avhdxFileExists } {
			$expectedVmName = 'my VM name'
			Mock Get-VM { 
				@{ State = 'not off' }
			}
			Mock Stop-VM { }
			Mock Get-VMHardDiskDrive {
				if ($avhdxFileExists) {
					$path = 'theFile.avhdx'
				}
				else {
					$path = 'theFile.otherExtension'
				}
				@{ Path = $path }
			}
			Mock Start-Sleep { }
			Mock Write-Log {}

			Stop-VirtualMachineForBaseImageProvisioning -Name $expectedVmName

			if ($avhdxFileExists) {
				Should -Invoke -CommandName Start-Sleep -Times 30 -ParameterFilter { $Seconds -eq 5 }
			}
			else {
				Should -Invoke -CommandName Start-Sleep -Times 0
			}
		}
	}
}

Describe 'Remove-SshKeyFromKnownHostsFile' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			Mock Get-IsValidIPv4Address { $false }
			$expectedIP = 'any IP value'

			{ Remove-SshKeyFromKnownHostsFile } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
			
			Should -Invoke -CommandName Get-IsValidIPv4Address -Times 0
			
			{ Remove-SshKeyFromKnownHostsFile -IpAddress $expectedIP } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

			Should -Invoke -CommandName Get-IsValidIPv4Address -ParameterFilter { $value -eq $expectedIP }
		}
	}
}

Describe 'Copy-LocalPublicSshKeyToRemoteComputer' -Tag 'unit', 'ci', 'baseimage' {
	It 'arguments validation' {
		InModuleScope $moduleName {
			Mock Get-IsValidIPv4Address { $true }
			Mock Assert-LegalCharactersInPath { $true }
			$expectedLocalPublicKeyPath = 'my public key path'
			$invalidValues = @($null, '', '   ')

			$invalidValues | & { param ([Parameter(ValueFromPipeline = $true)][string]$InvalidValue) 
				process {
					{ Copy-LocalPublicSshKeyToRemoteComputer -UserName $InvalidValue -UserPwd '' -IpAddress '172.19.1.1' -LocalPublicKeyPath $expectedLocalPublicKeyPath } | Get-ExceptionMessage | Should -BeLike '*UserName*'
				}
			}
			{ Copy-LocalPublicSshKeyToRemoteComputer -UserPwd '' -IpAddress '172.19.1.1' -LocalPublicKeyPath $expectedLocalPublicKeyPath } | Get-ExceptionMessage | Should -BeLike '*UserName*'
			{ Copy-LocalPublicSshKeyToRemoteComputer -UserName 'myName' -IpAddress '172.19.1.1' -LocalPublicKeyPath $expectedLocalPublicKeyPath } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
			{ Copy-LocalPublicSshKeyToRemoteComputer -UserName 'myName' -UserPwd '' -LocalPublicKeyPath $expectedLocalPublicKeyPath } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
			{ Copy-LocalPublicSshKeyToRemoteComputer -UserName 'myName' -UserPwd '' -IpAddress '172.19.1.1' } | Get-ExceptionMessage | Should -BeLike '*LocalPublicKeyPath*'

			Should -Invoke -CommandName Get-IsValidIPv4Address -ParameterFilter { $Value -eq '172.19.1.1' }
			Should -Invoke -CommandName Assert-LegalCharactersInPath -ParameterFilter { $Path -eq $expectedLocalPublicKeyPath }
		}
	}
	It 'performs copy' {
		InModuleScope $moduleName {
			$userName = 'my username'
			$expectedUserPwd = 'my user pwd'
			$ipAddress = 'my IP address'
			$expectedLocalPublicKeyPath = 'my local public key path'
			$publicKeyFileName = 'my public key filename'
			Mock Get-IsValidIPv4Address { $true }
			Mock Assert-LegalCharactersInPath { $true }
			Mock Assert-Path { 'path asserted' }
			Mock Split-Path { $publicKeyFileName } -ParameterFilter { $Path -eq $expectedLocalPublicKeyPath -and $Leaf -eq $true }
			Mock Copy-FromToMaster { }
			Mock ExecCmdMaster { }

			Copy-LocalPublicSshKeyToRemoteComputer -UserName $userName -UserPwd $expectedUserPwd -IpAddress $ipAddress -LocalPublicKeyPath $expectedLocalPublicKeyPath

			Should -Invoke -CommandName Assert-Path -Times 1 -ParameterFilter { $Path -eq $expectedLocalPublicKeyPath -and $PathType -eq 'Leaf' -and $ShallExist -eq $true }
			$expectedUser = "$userName@$ipAddress"
			$expectedTargetPath = "/tmp/$publicKeyFileName"
			$expectedRemoteTargetPath = "$expectedUser`:$expectedTargetPath"
			Should -Invoke -CommandName Copy-FromToMaster -Times 1 -ParameterFilter { $Source -eq $expectedLocalPublicKeyPath -and $Target -eq $expectedRemoteTargetPath -and $UsePwd -eq $true }
			Should -Invoke -CommandName ExecCmdMaster -Times 1 -ParameterFilter { $CmdToExecute -eq 'sudo mkdir -p ~/.ssh' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
			$expectedCommand = "sudo cat $expectedTargetPath | sudo tee ~/.ssh/authorized_keys"
			Should -Invoke -CommandName ExecCmdMaster -Times 1 -ParameterFilter { $CmdToExecute -eq $expectedCommand -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
		}
	}
}







		

