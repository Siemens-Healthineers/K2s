# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$commonModule = "$PSScriptRoot\common.module.psm1"

Import-Module $commonModule

$serviceName = Get-ServiceName

$status = $(nssm status $serviceName)

$isNginxRunningProp = @{Name = 'IsNginxRunning'; Value = ($status -contains 'SERVICE_RUNNING'); Okay = ($status -contains 'SERVICE_RUNNING') }
if ($isNginxRunningProp.Value -eq $true) {
    $isNginxRunningProp.Message = 'The nginx reverse proxy is working'
}
else {
    $msg = "The nginx reverse proxy is not working. Please check logs under 'C:\var\log\nginx\nginx_stderr.log' and check if port 80 or 443 is already in use. You can change ports under 'bin\nginx\nginx.conf'. Restart service afterwads with 'nssm restart $serviceName'."
    $isNginxRunningProp.Message = $msg
} 

return , @($isNginxRunningProp)