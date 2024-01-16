# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$status = $(nssm status extHttpAccess-nginx)

$isNginxRunningProp = @{Name = 'isNginxRunningProp'; Value = ($status -contains "SERVICE_RUNNING"); Okay = ($status -contains "SERVICE_RUNNING") }
if ($isNginxRunningProp.Value -eq $true) {
    $isNginxRunningProp.Message = 'The nginx reverse proxy is working'
}
else {
    $isNginxRunningProp.Message = "The nginx reverse proxy is not working. Please check logs under 'C:\var\log\nginx\nginx_stderr.log' and check if port 80 or 443 is already in use. You can change ports under 'bin\nginx\nginx.conf'. Restart service afterwads with 'nssm restart extHttpAccess-nginx'."
} 

return ,@($isNginxRunningProp)