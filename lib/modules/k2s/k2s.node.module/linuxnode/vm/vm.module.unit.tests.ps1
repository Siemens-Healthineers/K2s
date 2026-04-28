# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot/vm.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Invoke-SSHOnce' -Tag 'unit', 'ci', 'vm' {
    Context 'Socket warning filtering' {
        It 'filters socket warning and sets HadSocketWarning flag' {
            InModuleScope $moduleName {
                # Arrange: mock ssh.exe to return socket warning + real output
                $script:sshExe = 'ssh.exe'
                Mock -CommandName 'ssh.exe' -MockWith {
                    'command output'
                    Write-Error 'close - IO is still pending on closed socket. read:1, write:0, io:0000027287D7CD60'
                    $global:LASTEXITCODE = 1
                }

                # Act
                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                # Assert
                $result.HadSocketWarning | Should -BeTrue
                $result.OutputLines | Should -Contain 'command output'
                $result.OutputLines | Should -Not -Contain 'close - IO is still pending on closed socket. read:1, write:0, io:0000027287D7CD60'
            }
        }

        It 'returns no socket warning flag for clean output' {
            InModuleScope $moduleName {
                Mock -CommandName 'ssh.exe' -MockWith {
                    'clean output'
                    $global:LASTEXITCODE = 0
                }

                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                $result.HadSocketWarning | Should -BeFalse
                $result.OutputLines | Should -Contain 'clean output'
                $result.ExitCode | Should -Be 0
            }
        }

        It 'filters Warning: Permanently added messages' {
            InModuleScope $moduleName {
                Mock -CommandName 'ssh.exe' -MockWith {
                    Write-Error "Warning: Permanently added '172.19.1.100' (ED25519) to the list of known hosts."
                    'real output'
                    $global:LASTEXITCODE = 0
                }

                $result = Invoke-SSHOnce -SshExePath 'ssh.exe' -Params @('-n', 'user@host', 'echo test')

                $result.OutputLines | Should -Contain 'real output'
                $result.OutputLines.Count | Should -Be 1
            }
        }
    }
}

Describe 'Invoke-SSHWithKey socket warning retry' -Tag 'unit', 'ci', 'vm' {
    Context 'Socket warning with output' {
        It 'treats as success and returns clean output' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @('passwd: password changed.')
                        ExitCode         = 1
                        HadSocketWarning = $true
                    }
                }

                $output = Invoke-SSHWithKey -Command 'sudo passwd -d remote' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be 'passwd: password changed.'
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }

    Context 'Socket warning with no output and exit code 255' {
        It 'treats as success without retry' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 255
                        HadSocketWarning = $true
                    }
                }

                $output = Invoke-SSHWithKey -Command 'sudo touch /tmp/test' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be ''
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }

    Context 'Socket warning with no output and small non-zero exit code' {
        It 'retries and succeeds when retry returns exit code 0' {
            InModuleScope $moduleName {
                $script:callCount = 0
                Mock Invoke-SSHOnce -MockWith {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $true
                        }
                    } else {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 0
                            HadSocketWarning = $false
                        }
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'sudo touch /tmp/test' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
                Should -Invoke Start-Sleep -Times 1 -Exactly
            }
        }

        It 'retries and succeeds when retry also has socket warning' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 1
                        HadSocketWarning = $true
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'sudo systemctl reload ssh' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
            }
        }

        It 'retries and preserves error when retry fails without socket warning' {
            InModuleScope $moduleName {
                $script:callCount = 0
                Mock Invoke-SSHOnce -MockWith {
                    $script:callCount++
                    if ($script:callCount -eq 1) {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $true
                        }
                    } else {
                        [pscustomobject]@{
                            OutputLines      = @()
                            ExitCode         = 1
                            HadSocketWarning = $false
                        }
                    }
                }
                Mock Start-Sleep {}

                $output = Invoke-SSHWithKey -Command 'bad-command' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 1
                Should -Invoke Invoke-SSHOnce -Times 2 -Exactly
            }
        }
    }

    Context 'No socket warning' {
        It 'preserves non-zero exit code without retry' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @()
                        ExitCode         = 127
                        HadSocketWarning = $false
                    }
                }

                $output = Invoke-SSHWithKey -Command 'nonexistent-command' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 127
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }

        It 'preserves exit code 0 and returns output' {
            InModuleScope $moduleName {
                Mock Invoke-SSHOnce -MockWith {
                    [pscustomobject]@{
                        OutputLines      = @('hello world')
                        ExitCode         = 0
                        HadSocketWarning = $false
                    }
                }

                $output = Invoke-SSHWithKey -Command 'echo hello world' -IpAddress '172.19.1.100'

                $LASTEXITCODE | Should -Be 0
                $output | Should -Be 'hello world'
                Should -Invoke Invoke-SSHOnce -Times 1 -Exactly
            }
        }
    }
}

Describe 'Invoke-ExeWithAsciiEncoding' -Tag 'unit','ci','vm'  {
    Context 'PipeInput provided' {
        It 'returns piped text when executing system more.com' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\more.com")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\more.com"
                $args = @('')
                $text = 'yes'
                $originalIn = [Console]::InputEncoding.WebName
                $originalOut = [Console]::OutputEncoding.WebName
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args -PipeInput $text
                ($result -join '').Trim() | Should -Be $text
                [Console]::InputEncoding.WebName | Should -Be $originalIn
                [Console]::OutputEncoding.WebName | Should -Be $originalOut
            }
        }
    }
    Context 'No PipeInput, arguments echo output'  {
        It 'captures output' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\cmd.exe")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\cmd.exe"
                $args = @('/c', 'echo', 'log-line')
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args
                ($result -join '').Trim() | Should -Be 'log-line'
            }
        }
    }
}
