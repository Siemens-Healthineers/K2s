# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot/../log/log.module.psm1"

Import-Module $logModule

$script = $MyInvocation.MyCommand.Name

<#
.SYNOPSIS
Sends a message to the standard output.

.DESCRIPTION
Serializes the message to JSON, compresses and encodes it base64-wise and sends it to the standard output.

.PARAMETER MessageType
The type of the message

.PARAMETER Message
The message

.EXAMPLE
Send-ToCli -MessageType "my-type" -Message @{Name = "Thomas"}
#>
function Send-ToCli {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Type of the data message to be sent')]
        [string] $MessageType = $(throw 'Please specify the message type.'),
        [parameter(Mandatory = $false, HelpMessage = 'The data message as arbitrary object')]
        [object] $Message = $(throw 'Please specify the message.')
    )
    $function = $MyInvocation.MyCommand.Name
    $maxPayloadLength = 8191    

    Write-Log "[$script::$function] Converting message of type '$MessageType' to JSON.."

    $json = ConvertTo-Json -InputObject $Message -Compress -Depth 100

    Write-Log "[$script::$function] message converted"

    $memoryStream = New-Object System.IO.MemoryStream
    $compressionStream = New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode]::Compress)

    $streamWriter = New-Object System.IO.StreamWriter($compressionStream)
    $streamWriter.Write($json)
    $streamWriter.Close();

    Write-Log "[$script::$function] JSON compressed"

    $payload = [System.Convert]::ToBase64String($memoryStream.ToArray())

    Write-Log "[$script::$function] JSON base64 encoded"

    $cliOutput = "#pm#$MessageType#$payload"

    if ($cliOutput.Length -gt $maxPayloadLength ) {
        throw "Payload length exceeds max length of $($maxPayloadLength): $($cliOutput.Length). This might lead to data loss."
    }

    Write-Output $cliOutput

    Write-Log "[$script::$function] message sent via CLI"
}

Export-ModuleMember -Function Send-ToCli