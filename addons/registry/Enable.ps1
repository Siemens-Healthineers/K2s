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
    [pscustomobject] $Config
)

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
Import-Module $addonsModule

$registryFunctionsModule = "$PSScriptRoot\..\..\smallsetup\helpers\RegistryFunctions.module.psm1"
Import-Module $registryFunctionsModule -DisableNameChecking

$K8sSetup = Get-Installedk2sSetupType

$registryIP = $global:IP_Master
$registryName = 'k2s-registry.local'
$registryNameWithoutPort = $registryName
if ($Nodeport -gt 0) {
    if ($Nodeport -eq 30094) {
        Log-ErrorWithThrow 'Nodeport 30094 is already reserved! Please use another one!'
        # reserved for dcgm-exporter from nvidia for monitoring addon
    }
    $registryName = $($registryName + ':' + "$Nodeport")
}

function Test-NginxIngressControllerAvailability {
    $existingServices = $(&$global:BinPath\kubectl.exe get service -n ingress-nginx -o yaml)
    if ("$existingServices" -match '.*ingress-nginx-controller.*') {
        return $true
    }
    return $false
}

function Test-TraefikIngressControllerAvailability {
    $existingServices = $(&$global:BinPath\kubectl.exe get service -n traefik -o yaml)
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
            kubectl apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-nginx-ingress.yaml" | Write-Log
            break
        }
        'traefik' {
            kubectl apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-traefik-ingress.yaml" | Write-Log
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

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name 'registry') -eq $true) {
    Write-Log "Addon 'registry' is already enabled, nothing to do."
    exit 0
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
        Log-ErrorWithThrow 'Username must not be empty!'
    }
    $password = Read-Host 'Enter password' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $password)
    $password = $cred.GetNetworkCredential().Password
    if ($password -eq '') {
        Log-ErrorWithThrow 'Password must not be empty!'
    }
}

# Create folder structure for certificates and authentication files
Write-Log 'Creating authentification files and secrets' -Console
ExecCmdMaster 'sudo mkdir -m 777 -p /registry'
#ExecCmdMaster 'sudo mkdir -m 777 /registry/certs'
ExecCmdMaster 'sudo mkdir -m 777 /registry/auth 2>&1'
ExecCmdMaster 'sudo mkdir -m 777 /registry/repository 2>&1'
#ExecCmdMaster 'cd /registry && sudo openssl req -x509 -newkey rsa:4096 -days 365 -nodes -sha256 -keyout certs/tls.key -out certs/tls.crt -subj "/CN=k2s-registry" -addext "subjectAltName=DNS:k2s-registry"'
ExecCmdMaster "container=`$(sudo buildah from public.ecr.aws/docker/library/registry:2)` && sudo buildah run --isolation=chroot `$container` apk add apache2-utils && sudo buildah run --isolation=chroot `$container` htpasswd -Bbn `'$username`' `'$password'` | sudo tee /registry/auth/htpasswd 1>/dev/null && sudo buildah rm `$container" -NoLog

# Create secrets
#ExecCmdMaster 'sudo chmod 744 /registry/certs/tls.key'
kubectl create namespace registry | Write-Log
#ExecCmdMaster 'kubectl create secret tls certs-secret --cert=/registry/certs/tls.crt --key=/registry/certs/tls.key -n registry'
ExecCmdMaster 'kubectl create secret generic auth-secret --from-file=/registry/auth/htpasswd -n registry'

# Apply registry pod with persistent volume
Write-Log 'Creating local registry' -Console
kubectl apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry.yaml" | Write-Log
if ($Nodeport -eq 0) {
    # Deploy ingress here
    Deploy-IngressForRegistry -Ingress:$Ingress
}
else {
    kubectl apply -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry-nodeport.yaml" | Write-Log
    $patchJson = ''
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $patchJson = '{"spec":{"ports":[{"nodePort":' + $Nodeport + ',"port": 80,"protocol": "TCP","targetPort": 5000}]}}'
    }
    else {
        $patchJson = '{\"spec\":{\"ports\":[{\"nodePort\":' + $Nodeport + ',\"port\": 80,\"protocol\": \"TCP\",\"targetPort\": 5000}]}}'
    }

    &$global:BinPath\kubectl.exe patch svc k2s-registry -p "$patchJson" -n registry | Write-Log
}

kubectl wait --timeout=60s --for=condition=Ready -n registry pod/k2s-registry-pod | Write-Log
if (!$?) {
    Log-ErrorWithThrow 'k2s-registry did not start in time! Please disable addon and try to enable again!'
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
kubectl create secret docker-registry 'k2s-registry' --docker-server=$registryName --docker-username=$username --docker-password=$password | Write-Log

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
        Log-ErrorWithThrow 'Login to private registry not possible! Please disable addon and try to enable it again!'
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
