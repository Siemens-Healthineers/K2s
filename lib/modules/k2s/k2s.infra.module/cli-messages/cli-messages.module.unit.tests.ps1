# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\cli-messages.module.psm1"

    $moduleName = (Import-Module $module -Force -PassThru).Name
}

Describe 'Send-ToCli' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'message type not specified' {
        It 'throws an error' {
            { Send-ToCli -Message 'test message' } | Should -Throw
        }
    }

    Context 'message not specified' {
        It 'throws an error' {
            { Send-ToCli -MessageType 'test type' } | Should -Throw
        }
    }

    Context 'message and type are valid' {
        BeforeAll {
            $message = @{Name = 'Test'; Successful = $true }
            function ConvertFrom-CompressedString {
                param (
                    [Parameter(Mandatory)]
                    [string]
                    $CompressedString
                )

                $bytes = [System.Convert]::FromBase64String($CompressedString)

                $memoryStream = New-Object System.IO.MemoryStream
                $memoryStream.Write($bytes, 0, $bytes.Length)
                $memoryStream.Seek(0, 0) | Out-Null

                $decompressionStream = New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode]::Decompress)

                $streamReader = New-Object System.IO.StreamReader($decompressionStream)

                $json = $streamReader.ReadToEnd()

                $streamReader.Close()
                $memoryStream.Close()

                return ConvertFrom-Json $json
            }
        }

        It 'CLI message is structured correctly' {
            $type = 'unit test'

            $output = Send-ToCli -Message $message -MessageType $type

            $output | Should -BeLike "#pm#$type#*"
        }

        It 'compress and encodes the data correctly' {
            $output = Send-ToCli -Message $message -MessageType 'test'

            $obj = ConvertFrom-CompressedString (($output -split '#')[3])

            $obj.Name | Should -Be $message.Name
            $obj.Successful | Should -Be $message.Successful
        }
    }

    Context 'message payload exceeds CLI line length limit of 8191' {
        BeforeAll {
            $testObj = @{
                Name      = 'Gopher'
                Language  = 'Go'
                Level     = 'intermediate'
                Timestamp = Get-Date -Format 'o'
                List      = @{
                    P1 = 'value1'
                    P3 = 'value2'
                    P4 = 'value3'
                }
            }

            $length = 10000
            $longList = New-Object 'object[]' $length

            for ($i = 0; $i -lt $length; $i++) {
                $longList[$i] = $testObj
            }
        }

        It 'throws an error' {
            { Send-ToCli -MessageType 'test' -Message $longList } | Should -Throw
        }
    }
}