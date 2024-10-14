# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

Write-Log 'Registering windows_exporter service'

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
$logDir = "$($global:SystemDriveLetter):\var\log\windows_exporter"
if (!(Test-Path($logDir))) {
    mkdir $logDir -Force | Out-Null
}

&$global:NssmInstallDirectory\nssm install windows_exporter $global:ExecutableFolderPath\windows_exporter.exe

# possible to add --log.level="debug"
&$global:NssmInstallDirectory\nssm set windows_exporter AppParameters --web.listen-address=":9100" --collectors.enabled="cpu,cs,logical_disk,net,os,service,system,cpu_info,thermalzone,container" --collector.service.services-where "`"`"Name='kubelet' OR Name='kubeproxy' OR Name='flanneld' OR Name='windows_exporter' OR Name LIKE '%docker%'`"`"" --collector.logical_disk.volume-blacklist 'HarddiskVolume.*' | Out-Null
# cpu,cs,logical_disk,net,os,service,system,cpu_info,thermalzone,time,process,hyperv

&$global:NssmInstallDirectory\nssm set windows_exporter AppDirectory $global:KubernetesPath | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppStdout "${logDir}\windows_exporter_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppStderr "${logDir}\windows_exporter_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set windows_exporter Start SERVICE_AUTO_START | Out-Null

Start-Service windows_exporter -WarningAction SilentlyContinue
