# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Load the module to be tested
Import-Module "$PSScriptRoot\log.module.psm1"


Describe "Reset-LogFile" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        $global:k2sLogFile = $mockLogFile
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should delete the log file when AppendLogFile is false" {
        Reset-LogFile -AppendLogFile:$false
        Test-Path $mockLogFile | Should -Be $false
    }

    It "should not delete the log file when AppendLogFile is true" {
        Reset-LogFile -AppendLogFile:$true
        Test-Path $mockLogFile | Should -Be $true
    }
}

Describe "Get-k2sLogDirectory" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        $global:k2sLogFile = $mockLogFile
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should return the log directory path" {
        $result = Get-k2sLogDirectory
        $result | Should -Be (Split-Path -Path $mockLogFile -Parent)
    }
}

Describe "Get-LogFilePath" {
    BeforeEach {
        $mockLogFile = "$env:TEMP\mock.log"
        $global:k2sLogFile = $mockLogFile
    }

    AfterEach {
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should return the log file path" {
        $result = Get-LogFilePath
        $result | Should -Be $mockLogFile
    }
}

Describe "Save-k2sLogDirectory" {
    BeforeEach {
        $mockVarLogDir = "$env:TEMP\mock_var_log"
        $mockLogFile = "$mockVarLogDir\k2s.log"
        $global:k2sLogFile = $mockLogFile

        # Create mock log directory and file
        New-Item -ItemType Directory -Path $mockVarLogDir | Out-Null
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        Remove-Item -Path "$env:TEMP\k2s_log_*" -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:TEMP\mock_var_log" -Force -Recurse -ErrorAction SilentlyContinue
    }

    It "should back up logs to a zip file in the TEMP directory" {
        Save-k2sLogDirectory -VarLogDirectory "$env:TEMP\mock_var_log"
        $backupZip = Get-ChildItem -Path "$env:TEMP" -Filter "k2s_log_*.zip"
        $backupZip | Should -Not -BeNullOrEmpty
    }   
}

Describe "Write-Log Function Tests" {
    BeforeEach {
        # Mock the log file path
        $mockLogFile = "$env:TEMP\mock.log"
        $global:k2sLogFile = $mockLogFile

        # Create the mock log file
        New-Item -ItemType File -Path $mockLogFile | Out-Null
    }

    AfterEach {
        # Clean up the mock log file
        Remove-Item -Path $mockLogFile -Force -ErrorAction SilentlyContinue
    }

    It "should write a message to the log file" {
        # Arrange
        $message = "Test log message"

        # Act
        Write-Log -Messages $message

        # Assert
        $logContent = Get-Content -Path $mockLogFile
        $logContent | Should -Match "\| Msg: Test log message \|"
    }  

    It "should write a message to the console with specific format when -Console is used" {
        # Arrange
        $message = "Test console message"
        $expectedFormat = "\[\d{2}:\d{2}:\d{2}\] Test console message"

        # Act
        $output = & {
            Write-Log -Messages $message -Console
        } *>&1 # Capture console output

        # Assert
        $output | Should -Match $expectedFormat
        $logContent = Get-Content -Path $mockLogFile
        $logContent | Should -Match "\| Msg: Test console message \|"
    }

    InModuleScope log.module {
        It "should call Write-Host -NoNewline when Write-Log is called with -Progress -Console" {
            # Arrange
            $progressMessage = "ProgressTest"
            Mock Write-Host { } -ModuleName 'log.module'

            # Act
            Write-Log -Messages $progressMessage -Progress -Console
            Write-Log -Messages $progressMessage -Progress -Console

            # Assert           
            Assert-MockCalled Write-Host -Times 2 -Exactly -ParameterFilter {
                $NoNewline -eq $true -and
                $Object -eq $progressMessage
            }
        }

        It "should output the raw message when -Raw is used" {
        # Arrange
        $msg = "raw message"
        # Act
        $output = & {
            Write-ConsoleMessage -Message $msg -ConsoleMessage "ignored" -LogFileMessage "ignored" -Raw
        }
        # Assert
        $output | Should -Be $msg
        }

        It "should output the ssh-formatted message when -Ssh is used" {
        # Arrange
        $msg = "ssh message"
        # Act
        $output = & {
            Write-ConsoleMessage -Message $msg -ConsoleMessage "ignored" -LogFileMessage "ignored" -Ssh
        }
        # Assert
        $output | Should -Be "#ssh#$msg"
        }
    }
}