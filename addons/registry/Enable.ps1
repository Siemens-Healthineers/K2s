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
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('ingress-nginx', 'traefik')]
    [string] $Ingress = 'ingress-nginx',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
function Test-NginxIngressControllerAvailability {
    $existingServices = $(&$global:KubectlExe get service -n ingress-nginx -o yaml)
    if ("$existingServices" -match '.*ingress-nginx-controller.*') {
        return $true
    }
    return $false
}

function Test-TraefikIngressControllerAvailability {
    $existingServices = $(&$global:KubectlExe get service -n traefik -o yaml)
    if ("$existingServices" -match '.*traefik.*') {
        return $true
    }
    return $false
}

function Enable-IngressAddon([string]$Ingress) {
    switch ($Ingress) {
        'ingress-nginx' {
            &"$PSScriptRoot\..\ingress-nginx\Enable.ps1"
            break
        }
        'traefik' {
            &"$PSScriptRoot\..\traefik\Enable.ps1"
            break
        }
    }
}

function Deploy-IngressForRegistry([string]$Ingress) {
    switch ($Ingress) {
        'ingress-nginx' {
            &$global:KubectlExe apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-nginx-ingress.yaml" | Write-Log
            break
        }
        'traefik' {
            &$global:KubectlExe apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-traefik-ingress.yaml" | Write-Log
            break
        }
    }
}

function Set-Containerd-Config() {
    param(
        [Parameter()]
        [String]
        $registryName,
        [Parameter()]
        [String]
        $authJson
    )

    $containerdConfig = "$global:KubernetesPath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#auth_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth] #auth_k2s_registry") } | Set-Content $containerdConfig
    }

    $authValuePlaceHolder = Get-Content $containerdConfig | Select-String '#auth_value_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $authValuePlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_ -replace $authValuePlaceHolder, "          auth = ""$auth"" #auth_value_k2s_registry" } | Set-Content $containerdConfig
    }

    $tlsPlaceHolder = Get-Content $containerdConfig | Select-String '#tls_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $tlsPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($tlsPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".tls] #tls_k2s_registry") } | Set-Content $containerdConfig
    }

    $mirrorPlaceHolder = Get-Content $containerdConfig | Select-String '#mirror_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $mirrorPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($mirrorPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.mirrors.""$registryName""] #mirror_k2s_registry") } | Set-Content $containerdConfig
    }

    $mirrorValuePlaceHolder = Get-Content $containerdConfig | Select-String '#mirror_value_k2s_registry' | Select-Object -ExpandProperty Line
    if ( $mirrorValuePlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($mirrorValuePlaceHolder, "          endpoint = [""http://$registryName""] #mirror_value_k2s_registry") } | Set-Content $containerdConfig
    }
}

function Restart-Services() {
    Write-Log 'Restarting services' -Console
    &$global:NssmInstallDirectory\nssm stop kubeproxy
    &$global:NssmInstallDirectory\nssm stop kubelet
    &$global:NssmInstallDirectory\nssm restart containerd
    &$global:NssmInstallDirectory\nssm start kubelet
    &$global:NssmInstallDirectory\nssm start kubeproxy
}

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryFunctionsModule = "$PSScriptRoot\..\..\smallsetup\helpers\RegistryFunctions.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $registryFunctionsModule, $infraModule -DisableNameChecking

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

if ((Test-IsAddonEnabled -Name 'registry') -eq $true) {
    $errMsg = "Addon 'registry' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$K8sSetup = Get-Installedk2sSetupType

$registryIP = $global:IP_Master
$registryName = 'k2s-registry.local'
$registryNameWithoutPort = $registryName
if ($Nodeport -gt 0) {
    if ($Nodeport -eq 30094) {
        $errMsg = 'Nodeport 30094 is already reserved, please use another one.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'port-already-in-use' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
        # reserved for dcgm-exporter from nvidia for monitoring addon
    }
    $registryName = $($registryName + ':' + "$Nodeport")
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
ExecCmdMaster 'sudo mkdir -m 777 -p /registry'
#ExecCmdMaster 'sudo mkdir -m 777 /registry/certs'
ExecCmdMaster 'sudo mkdir -m 777 /registry/auth 2>&1'
ExecCmdMaster 'sudo mkdir -m 777 /registry/repository 2>&1'
#ExecCmdMaster 'cd /registry && sudo openssl req -x509 -newkey rsa:4096 -days 365 -nodes -sha256 -keyout certs/tls.key -out certs/tls.crt -subj "/CN=k2s-registry" -addext "subjectAltName=DNS:k2s-registry"'

Install-DebianPackages -addon 'registry' -packages 'apache2-utils'
ExecCmdMaster "sudo htpasswd -Bbn `'$username`' `'$password'` | sudo tee /registry/auth/htpasswd 1>/dev/null" -NoLog

# Create secrets
#ExecCmdMaster 'sudo chmod 744 /registry/certs/tls.key'
&$global:KubectlExe create namespace registry | Write-Log
#ExecCmdMaster 'kubectl create secret tls certs-secret --cert=/registry/certs/tls.crt --key=/registry/certs/tls.key -n registry'
ExecCmdMaster 'kubectl create secret generic auth-secret --from-file=/registry/auth/htpasswd -n registry'

# Apply registry pod with persistent volume
Write-Log 'Creating local registry' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry.yaml" | Write-Log
if ($Nodeport -eq 0) {
    # Deploy ingress here
    Deploy-IngressForRegistry -Ingress:$Ingress
}
else {
    &$global:KubectlExe apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-nodeport.yaml" | Write-Log
    $patchJson = ''
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $patchJson = '{"spec":{"ports":[{"nodePort":' + $Nodeport + ',"port": 80,"protocol": "TCP","targetPort": 5000}]}}'
    }
    else {
        $patchJson = '{\"spec\":{\"ports\":[{\"nodePort\":' + $Nodeport + ',\"port\": 80,\"protocol\": \"TCP\",\"targetPort\": 5000}]}}'
    }

    &$global:KubectlExe patch svc k2s-registry -p "$patchJson" -n registry | Write-Log
}

&$global:KubectlExe wait --timeout=60s --for=condition=Ready -n registry pod/k2s-registry-pod | Write-Log
if (!$?) {
    $errMsg = 'k2s-registry did not start in time! Please disable addon and try to enable again!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$linuxOnly = Get-LinuxOnlyFromConfig

# Add k2s-registry service IP to /etc/hosts
Write-Log 'Configuring nodes access' -Console
$hostEntry = $($registryIP + ' ' + $registryNameWithoutPort)
ExecCmdMaster "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts"

if ($K8sSetup -eq 'k2s') {
    if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $hostEntry }).Contains($true)) {
        Add-Content 'C:\Windows\System32\drivers\etc\hosts' $hostEntry
    }
}
elseif ($K8sSetup -eq $global:SetupType_MultiVMK8s -and !$linuxOnly) {
    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        if (!$(Get-Content 'C:\Windows\System32\drivers\etc\hosts' | % { $_ -match $using:hostEntry }).Contains($true)) {
            Add-Content 'C:\Windows\System32\drivers\etc\hosts' $using:hostEntry
        }
    }
}

# Copy tls cert to nodes
#ExecCmdMaster 'sudo mkdir -p "/etc/containers/certs.d/k2s-registry.local"'
#ExecCmdMaster 'sudo cp -rf /registry/certs/tls.crt "/etc/containers/certs.d/k2s-registry.local/ca.crt"'

#New-Item $env:programdata\docker\certs.d -ItemType Directory -Force | Out-Null
#New-Item "$env:programdata\docker\certs.d\k2s-registry5000" -Force -ItemType Directory | Out-Null
#Copy-FromToMaster $($global:Remote_Master + ':/registry/certs/tls.crt') "$env:programdata\docker\certs.d\k2s-registry.local\ca.crt"

# Create secret for enabling all the nodes in the cluster to authenticate with private registry
&$global:KubectlExe create secret docker-registry 'k2s-registry' --docker-server=$registryName --docker-username=$username --docker-password=$password | Write-Log

# set insecure-registries (remove this section in case of self signed certificates)
if ($PSVersionTable.PSVersion.Major -gt 5) {
    ExecCmdMaster "grep location=\""k2s.*\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\""k2s.*\""\ninsecure=true/[[registry]]\nlocation=""$registryName""\ninsecure=true/g' /etc/containers/registries.conf"
    ExecCmdMaster "grep location=\""k2s.*\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=""$registryName""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}
else {
    ExecCmdMaster "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""k2s.*\\\""\ninsecure=true/[[registry]]\nlocation=\\\""$registryName\\\""\ninsecure=true/g' /etc/containers/registries.conf"
    ExecCmdMaster "grep location=\\\""k2s.*\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$registryName\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}

ExecCmdMaster 'sudo systemctl daemon-reload'
ExecCmdMaster 'sudo systemctl restart crio'

Start-Sleep 2

Login-Buildah -username $username -password $password -registry $registryName

$authJson = ExecCmdMaster 'sudo cat /root/.config/containers/auth.json' -NoLog | Out-String

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($K8sSetup -eq 'k2s') {
    $storageLocalDrive = Get-StorageLocalDrive
    &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$registryName" --insecure-registry "$registryName" | Out-Null
    if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        &"$global:NssmInstallDirectory\nssm" restart docker
    }
    else {
        &"$global:NssmInstallDirectory\nssm" start docker
    }

    Login-Docker -username $username -password $password -registry $registryName

    # set authentification for containerd
    Set-Containerd-Config -registryName $registryName -authJson $authJson

    Restart-Services | Write-Log -Console
}
elseif ($K8sSetup -eq $global:SetupType_MultiVMK8s -and !$linuxOnly) {
    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1

        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true
        $registryFunctionsModule = "$env:SystemDrive\k\smallsetup\helpers\RegistryFunctions.module.psm1"
        Import-Module $registryFunctionsModule -DisableNameChecking

        &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root 'C:\docker' --log-level debug --allow-nondistributable-artifacts "$using:registryName" --insecure-registry "$using:registryName" | Out-Null
        if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
            &"$global:NssmInstallDirectory\nssm" restart docker
        }
        else {
            &"$global:NssmInstallDirectory\nssm" start docker
        }

        Login-Docker -username $using:username -password $using:password -registry $using:registryName
    }

    Invoke-Command -Session $session -ScriptBlock ${Function:Set-Containerd-Config} -ArgumentList $registryName, $authJson
    Invoke-Command -Session $session -ScriptBlock ${Function:Restart-Services} | Write-Log -Console

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
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName

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