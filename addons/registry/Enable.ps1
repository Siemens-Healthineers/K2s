# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables k2s-registry in the cluster to the private-registry namespace

.DESCRIPTION
The local registry allows to push/pull images to/from the local volume of KubeMaster.
Each node inside the cluster can connect to the registry.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\registry\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use default credentials')]
    [switch] $UseDefaultCredentials = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Nodeport for registry access')]
    [ValidateRange(30000, 32767)]
    [Int] $Nodeport = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'traefik')]
    [string] $Ingress = 'nginx',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryModule = "$PSScriptRoot\registry.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $registryModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'registry' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'registry' })) -eq $true) {
    $errMsg = "Addon 'registry' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

# Enable ingress controller in case no nodeport is specified
if ($Nodeport -eq 0) {
    if (!(Test-NginxIngressControllerAvailability) -and !(Test-TraefikIngressControllerAvailability)) {
        #Enable required ingress addon
        Enable-IngressAddon -Ingress:$Ingress
    }
    elseif (Test-TraefikIngressControllerAvailability) {
        $Ingress = 'traefik'
        Write-Log 'Using traefik ingress controller since it has been already enabled' -Console
    }
}

if ($UseDefaultCredentials) {
    $username = 'admin'
    $password = 'admin'
}
else {
    # Ask user for credentials
    Write-Log 'Please specify credentials for registry access:' -Console
    $username = Read-Host 'Enter username'
    if ($username -eq '') {
        $errMsg = 'Username must not be empty!'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'username-invalid' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    $password = Read-Host 'Enter password' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $password)
    $password = $cred.GetNetworkCredential().Password
    if ($password -eq '') {
        $errMsg = 'Password must not be empty!'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'password-invalid' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

# Create folder structure for certificates and authentication files
Write-Log 'Creating authentification files and secrets' -Console
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 -p /registry').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 /registry/auth 2>&1').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -m 777 /registry/repository 2>&1').Output | Write-Log

Install-DebianPackages -addon 'registry' -packages 'apache2-utils'

(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo htpasswd -Bbn `'$username`' `'$password'` | sudo tee /registry/auth/htpasswd 1>/dev/null" -NoLog).Output | Write-Log

# Create secrets
(Invoke-Kubectl -Params 'create', 'namespace', 'registry').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'kubectl create secret generic auth-secret --from-file=/registry/auth/htpasswd -n registry').Output | Write-Log

# Apply registry pod with persistent volume
Write-Log 'Creating local registry' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\k2s-registry.yaml").Output | Write-Log
if ($Nodeport -eq 0) {
    Deploy-IngressForRegistry -Ingress:$Ingress
}
else {
    (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\k2s-registry-nodeport.yaml").Output | Write-Log

    $patchJson = ''
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $patchJson = '{"spec":{"ports":[{"nodePort":' + $Nodeport + ',"port": 80,"protocol": "TCP","targetPort": 5000}]}}'
    }
    else {
        $patchJson = '{\"spec\":{\"ports\":[{\"nodePort\":' + $Nodeport + ',\"port\": 80,\"protocol\": \"TCP\",\"targetPort\": 5000}]}}'
    }

    (Invoke-Kubectl -Params 'patch', 'svc', 'k2s-registry', '-p', "$patchJson", '-n', 'registry').Output | Write-Log
}

$kubectlCmd = (Invoke-Kubectl -Params 'wait', '--timeout=60s', '--for=condition=Ready', '-n', 'registry', 'pod/k2s-registry-pod')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'k2s-registry did not start in time! Please disable addon and try to enable again!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$registryName = 'k2s-registry.local'

Add-HostEntries -Url $registryName

if ($Nodeport -gt 0) {
    $registryName = "$($registryName):$Nodeport"
}

# Create secret for enabling all the nodes in the cluster to authenticate with private registry
(Invoke-Kubectl -Params 'create', 'secret', 'docker-registry', 'k2s-registry', "--docker-server=$registryName", "--docker-username=$username", "--docker-password=$password").Output | Write-Log

# set insecure-registries (remove this section in case of self signed certificates)
if ($PSVersionTable.PSVersion.Major -gt 5) {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\""k2s.*\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\""k2s.*\""\ninsecure=true/[[registry]]\nlocation=""$registryName""\ninsecure=true/g' /etc/containers/registries.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\""k2s.*\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=""$registryName""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf").Output | Write-Log
}
else {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""k2s.*\\\""\ninsecure=true/[[registry]]\nlocation=\\\""$registryName\\\""\ninsecure=true/g' /etc/containers/registries.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$registryName\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf").Output | Write-Log
}

(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log

Start-Sleep 2

Connect-Buildah -username $username -password $password -registry $registryName

$authJson = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo cat /root/.config/containers/auth.json').Output | Out-String

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($setupInfo.Name -eq 'k2s') {
    $storageLocalDrive = Get-StorageLocalDrive
    Set-ServiceProperty -Name 'docker' -PropertyName 'AppParameters' -Value "--exec-opt isolation=process --data-root ""$storageLocalDrive\docker"" --log-level debug --allow-nondistributable-artifacts $registryName --insecure-registry $registryName"
    if (Get-IsNssmServiceRunning('docker')) {
        Restart-NssmService('docker')
    }
    else {
        Start-NssmService('docker')
    }

    Connect-Docker -username $username -password $password -registry $registryName

    # set authentification for containerd
    Set-Containerd-Config -registryName $registryName -authJson $authJson

    Restart-Services | Write-Log -Console
}
elseif ($setupInfo.Name -eq 'MultiVMK8s' -and $setupInfo.LinuxOnly -ne $true) {
    $session = Open-DefaultWinVMRemoteSessionViaSSHKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        $infraModule = "$env:SystemDrive/k/lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
        $clusterModule = "$env:SystemDrive/k/lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
        $nodeModule = "$env:SystemDrive/k/lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"       

        Import-Module $infraModule, $clusterModule, $nodeModule

        Initialize-Logging -Nested:$true

        # TODO: --- code clone ---
        Set-ServiceProperty -Name 'docker' -PropertyName 'AppParameters' -Value "--exec-opt isolation=process --data-root 'C:\docker' --log-level debug --allow-nondistributable-artifacts $using:registryName --insecure-registry $using:registryName"
        if (Get-IsNssmServiceRunning('docker')) {
            Restart-NssmService('docker')
        }
        else {
            Start-NssmService('docker')
        }

        Connect-Docker -username $using:username -password $using:password -registry $using:registryName

        Set-Containerd-Config -registryName $registryName -authJson $authJson

        Restart-Services | Write-Log -Console
        # TODO: --- code clone ---
    }

    if (!$?) {
        $errMsg = 'Login to private registry not possible! Please disable addon and try to enable it again!'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'registry' })
Add-RegistryToSetupJson -Name $registryName
Set-ConfigLoggedInRegistry -Value $registryName

Write-Log ' ' -Console
Write-Log '                    USAGE NOTES' -Console
Write-Log " Registry is available via '$registryName' and you are logged in with:" -Console
Write-Log " username: $username" -Console
if ($UseDefaultCredentials) {
    Write-Log ' password: admin' -Console
}
else {
    Write-Log ' password: <your chosen password>' -Console
}
Write-Log ' ' -Console
Write-Log ' In order to push your images to the private registry you have to tag your images as in the following example:' -Console
Write-Log " $registryName/<yourImageName>:<yourImageTag>" -Console
Write-Log ' ' -Console
Write-Log ' Image pull secret available: k2s-registry' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}