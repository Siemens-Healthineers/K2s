
# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT


$infraModule = "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$provisioningModule = "$PSScriptRoot\..\baseimage\provisioning.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $provisioningModule, $vmModule

$kubernetesVersion = Get-DefaultK8sVersion

$wslConfigurationFilePath = '/etc/wsl.conf'

Function Assert-GeneralComputerPrequisites {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log 'Checking if the hostname contains only allowed characters...'
    [string]$hostname = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output
    if ([string]::IsNullOrWhiteSpace($hostname) -eq $true) {
        throw "The hostname of the computer with IP '$IpAddress' could not be retrieved."
    }
    $hasHostnameUppercaseChars = [regex]::IsMatch($hostname, '[^a-z]+')
    if ($hasHostnameUppercaseChars) {
        throw "The hostname '$hostname' of the computer reachable on IP '$IpAddress' contains not allowed characters. " +
        'Only a hostname that follows the pattern [a-z] is allowed.'
    }
    else {
        Write-Log ' ...done'
    }
}

Function Set-UpComputerBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    if ( $Proxy -ne '' ) {
        Write-Log "Setting proxy '$Proxy' for apt"
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo touch /etc/apt/apt.conf.d/proxy.conf' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo Acquire::http::Proxy \""$Proxy\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo Acquire::http::Proxy \\\""$Proxy\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        }
    }
}

Function Set-UpComputerAfterProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log 'Copying some dotfiles to remote computer ...'
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.inputrc' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_kubectl' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_docker' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_aliases' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd

    Write-Log 'Set local time zone in VM...'
    $timezoneForVm = 'Europe/Berlin'
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo timedatectl set-timezone $timezoneForVm" -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd).Output | Write-Log

    Write-Log 'Enable hushlogin...'
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'touch ~/.hushlogin' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd).Output | Write-Log
}

Function Install-KubernetesArtifacts {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion')
    )
    $remoteUser = "$UserName@$IpAddress"

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        } else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
    }

    Write-Log "Copying ZScaler Root CA certificate to computer with IP '$IpAddress'"
    $zScalerCertificateSourcePath = "$(Get-KubePath)\lib\modules\k2s\k2s.node.module\linuxnode\setup\certificate\ZScalerRootCA.crt"
    $zScalerCertificateTargetPath = "/tmp/ZScalerRootCA.crt"
    if ([string]::IsNullOrWhiteSpace($UserPwd)) {
        Copy-ToRemoteComputerViaSshKey -Source $zScalerCertificateSourcePath -Target $zScalerCertificateTargetPath -UserName $UserName -IpAddress $IpAddress
    } else {
        Copy-ToRemoteComputerViaUserAndPwd -Source $zScalerCertificateSourcePath -Target $zScalerCertificateTargetPath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    }

    &$executeRemoteCommand "sudo mv /tmp/ZScalerRootCA.crt /usr/local/share/ca-certificates/"
    &$executeRemoteCommand "sudo update-ca-certificates"
    Write-Log "Zscaler certificate added to CA certificates of computer with IP '$IpAddress'"

    Write-Log 'Configure bridged traffic'
    &$executeRemoteCommand 'echo overlay | sudo tee /etc/modules-load.d/k8s.conf'
    &$executeRemoteCommand 'echo br_netfilter | sudo tee /etc/modules-load.d/k8s.conf'
    &$executeRemoteCommand 'sudo modprobe overlay'
    &$executeRemoteCommand 'sudo modprobe br_netfilter'

    &$executeRemoteCommand 'echo net.bridge.bridge-nf-call-ip6tables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'
    &$executeRemoteCommand 'echo net.bridge.bridge-nf-call-iptables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'
    &$executeRemoteCommand 'echo net.ipv4.ip_forward = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'
    &$executeRemoteCommand 'sudo sysctl --system'

    &$executeRemoteCommand 'echo @reboot root mount --make-rshared / | sudo tee /etc/cron.d/sharedmount'

    Write-Log 'Prepare for Kubernetes installation'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gpg' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'

    Write-Log 'Install curl'
    &$executeRemoteCommand 'sudo apt-get update' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes curl' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'

    # we need major and minor for apt keys
    $proxyToAdd = ''
    if ($Proxy -ne '') {
        $proxyToAdd = " --Proxy $Proxy"
    }
    $pkgShortK8sVersion = $K8sVersion.Substring(0, $K8sVersion.lastIndexOf('.'))
    $kubernetesPublicKeyFilePath = '/tmp/kubernetes.key'
    &$executeRemoteCommand "sudo curl --retry 3 --retry-all-errors -fsSL https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/Release.key$proxyToAdd -o $kubernetesPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg $kubernetesPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "echo 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list"
    &$executeRemoteCommand "sudo rm -f $kubernetesPublicKeyFilePath" -IgnoreErrors

    # package locations for cri-o
    $crioPublicKeyFilePath = '/tmp/crio.key'
    &$executeRemoteCommand "sudo curl --retry 3 --retry-all-errors -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$pkgShortK8sVersion/deb/Release.key$proxyToAdd -o $crioPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "sudo gpg --dearmor -o /usr/share/keyrings/cri-o-apt-keyring.gpg $crioPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "echo 'deb [signed-by=/usr/share/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$pkgShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/cri-o.list"
    &$executeRemoteCommand "sudo rm -f $crioPublicKeyFilePath" -IgnoreErrors

    Write-Log 'Install other depended-on tools'
    &$executeRemoteCommand 'sudo apt-get update' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes apt-transport-https ca-certificates' -Retries 2 -RepairCmd 'sudo apt --fix-broken install'

    Write-Log 'Install cri-o'
    InstallAptPackages -FriendlyName 'cri-o' -Packages 'cri-o' -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    &$executeRemoteCommand 'sudo apt-mark hold cri-o'

    # increase timeout for crictl to connect to crio.sock
    &$executeRemoteCommand 'sudo touch /etc/crictl.yaml'
    &$executeRemoteCommand "grep timeout.* /etc/crictl.yaml | sudo sed -i 's/timeout.*/timeout: 30/g' /etc/crictl.yaml"
    &$executeRemoteCommand 'grep timeout.* /etc/crictl.yaml || echo timeout: 30 | sudo tee -a /etc/crictl.yaml'

    if ( $Proxy -ne '' ) {
        Write-Log 'Set proxy to CRI-O'
        &$executeRemoteCommand 'sudo mkdir -p /etc/systemd/system/crio.service.d'
        &$executeRemoteCommand 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf'
        &$executeRemoteCommand 'echo [Service] | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf'
        &$executeRemoteCommand "echo Environment=\'HTTP_PROXY=$Proxy\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
        &$executeRemoteCommand "echo Environment=\'HTTPS_PROXY=$Proxy\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
        &$executeRemoteCommand "echo Environment=\'http_proxy=$Proxy\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
        &$executeRemoteCommand "echo Environment=\'https_proxy=$Proxy\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
        &$executeRemoteCommand "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    }

    $token = Get-RegistryToken
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $jsonConfig = @{
            'auths' = @{
                'shsk2s.azurecr.io' = @{
                    'auth' = "$token"
                }
            }
        }
    }
    else {
        $jsonConfig = @{
            '"auths"' = @{
                '"shsk2s.azurecr.io"' = @{
                    '"auth"' = """$token"""
                }
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    &$executeRemoteCommand "echo -e '$jsonString' | sudo tee /tmp/auth.json" | Out-Null
    &$executeRemoteCommand 'sudo mkdir -p /root/.config/containers'
    &$executeRemoteCommand 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'

    Write-Log 'Configure CRI-O'
    # cri-o default cni bridge should have least priority
    $CRIO_CNI_FILE = '/etc/cni/net.d/10-crio-bridge.conf'
    &$executeRemoteCommand "[ -f $CRIO_CNI_FILE ] && sudo mv $CRIO_CNI_FILE /etc/cni/net.d/100-crio-bridge.conf || echo File does not exist, no renaming of cni file $CRIO_CNI_FILE.."
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand 'sudo echo unqualified-search-registries = [\"docker.io\"] | sudo tee -a /etc/containers/registries.conf'
    }
    else {
        &$executeRemoteCommand 'sudo echo unqualified-search-registries = [\\\"docker.io\\\"] | sudo tee -a /etc/containers/registries.conf'
    }

    $shortKubeVers = ($K8sVersion -replace 'v', '') + '-1.1'

    Write-Log 'Install kubetools (kubelet, kubeadm, kubectl)'
    &$executeRemoteCommand 'sudo apt-get update'
    InstallAptPackages -FriendlyName 'kubernetes' -Packages "kubelet=$shortKubeVers kubeadm=$shortKubeVers kubectl=$shortKubeVers" -TestExecutable 'kubectl' -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    &$executeRemoteCommand 'sudo apt-mark hold kubelet kubeadm kubectl'

    Write-Log 'Start CRI-O'
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'sudo systemctl enable crio' -IgnoreErrors
    &$executeRemoteCommand 'sudo systemctl start crio'

    $isWsl = Get-ConfigWslFlag
    Write-Log "Add WSL support?: $isWsl"
    if ( $isWsl ) {
        Write-Log 'Add cri-o fix for WSL'
        $configWSL = '/etc/crio/crio.conf.d/20-wsl.conf'
        &$executeRemoteCommand "echo [crio.runtime] | sudo tee -a $configWSL > /dev/null"
        &$executeRemoteCommand "echo add_inheritable_capabilities=true | sudo tee -a $configWSL > /dev/null"
        &$executeRemoteCommand "echo default_sysctls='[\`"net.ipv4.ip_unprivileged_port_start=0\`"]' | sudo tee -a $configWSL > /dev/null"
        &$executeRemoteCommand 'sudo systemctl restart crio'
    }

    Write-Log 'Pull images used by K8s'
    &$executeRemoteCommand "sudo kubeadm config images pull --kubernetes-version $K8sVersion"
}

Function Remove-KubernetesArtifacts {
    param (
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
    }

    &$executeRemoteCommand 'sudo systemctl stop kubelet'
    &$executeRemoteCommand 'sudo systemctl disable kubelet'

    &$executeRemoteCommand 'sudo systemctl stop crio'
    &$executeRemoteCommand 'sudo systemctl disable crio'

    &$executeRemoteCommand 'sudo systemctl daemon-reload'

    &$executeRemoteCommand 'sudo apt-get purge --yes --allow-change-held-packages kubelet kubeadm kubectl'

    &$executeRemoteCommand 'sudo rm -f /etc/containers/registries.conf'
    &$executeRemoteCommand 'sudo rm -f /etc/cni/net.d/100-crio-bridge.conf'
    &$executeRemoteCommand 'sudo rm -drf /root/.config/containers'
    &$executeRemoteCommand 'sudo rm -drf /etc/systemd/system/crio.service.d'
    &$executeRemoteCommand 'sudo rm -f /etc/crictl.yaml'

    &$executeRemoteCommand 'sudo apt-get remove --yes --allow-change-held-packages cri-o'

    &$executeRemoteCommand 'sudo rm -f /usr/share/keyrings/cri-o-apt-keyring.gpg'
    &$executeRemoteCommand 'sudo rm -f /etc/apt/sources.list.d/cri-o.list'

    &$executeRemoteCommand 'sudo rm -f /usr/share/keyrings/kubernetes-apt-keyring.gpg'
    &$executeRemoteCommand 'sudo rm -f /etc/apt/sources.list.d/kubernetes.list'

    &$executeRemoteCommand 'sudo rm -drf /etc/kubernetes'
    &$executeRemoteCommand 'sudo rm -drf /etc/crio'

    &$executeRemoteCommand 'sudo rm -f /etc/sysctl.d/k8s.conf'
    &$executeRemoteCommand 'sudo rm -f /etc/modules-load.d/k8s.conf'
    &$executeRemoteCommand 'sudo sysctl --system'

    &$executeRemoteCommand 'sudo apt-get purge --yes dnsmasq'
    &$executeRemoteCommand 'sudo apt-get purge --yes cri-o'
}

<#
.SYNOPSIS
Installs tools into the VM.
.DESCRIPTION
Installs the following tool:
- buildah (container image creation tool)
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER Proxy
The proxy to use.
#>
Function Install-Tools {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Start installing tools in the Linux VM'

    # INSTALL buildah FROM TESTING REPO IN ORDER TO GET A NEWER VERSION
    #################################################################################################################################################################
    Write-Log 'Install container image creation tool: buildah'                                                                                                   #
    #First install buildah from latest debian bullseye                                                                                                              #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Options::="--force-confnew" install buildah --yes'                                   #
    #Remove chrony as it is unstable with latest version of buildah                                                                                                 #
    #&$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get remove chrony --yes'                                                                          #
    #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes software-properties-common'                                                 #
    #
    #Now update apt sources to get latest from bookworm                                                                                                              #
    AddAptRepo -RepoDebString 'deb http://deb.debian.org/debian bookworm main' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"                                        #
    AddAptRepo -RepoDebString 'deb http://deb.debian.org/debian-security/ bookworm-security main' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"                     #
    #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes'                                                                             #
    #&$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get remove chrony --yes'                                                                          #
    #
    #Install latest from bookworm now                                                                                                                                #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -t bookworm --no-install-recommends --no-install-suggests buildah --yes'              #
    &$executeRemoteCommand 'sudo buildah -v'                                                                                                                          #
    #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq --yes'                                                                         #
    #
    #Remove bookworm source now                                                                                                                                      #
    &$executeRemoteCommand "sudo apt-add-repository 'deb http://deb.debian.org/debian bookworm main' -r"                                                              #
    &$executeRemoteCommand "sudo apt-add-repository 'deb http://deb.debian.org/debian-security/ bookworm-security main' -r"                                           #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes'                                                                             #
    #################################################################################################################################################################

    # Temporary fix for [master] not recognized in buildah 1.22.3, we comment the section as this is only specific to container engine
    # Issue is fixed in buildah 1.26 but exists in experimental stage
    #&$executeRemoteCommand "sudo sed -i 's/\[machine/#&/' /usr/share/containers/containers.conf"

    if ($Proxy -ne '') {
        &$executeRemoteCommand 'echo [engine] | sudo tee -a /etc/containers/containers.conf'
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            &$executeRemoteCommand "echo env = [\""https_proxy=$Proxy\""] | sudo tee -a /etc/containers/containers.conf"
        }
        else {
            &$executeRemoteCommand "echo env = [\\\""https_proxy=$Proxy\\\""] | sudo tee -a /etc/containers/containers.conf"
        }
    }

    $token = Get-RegistryToken
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $jsonConfig = @{
            'auths' = @{
                'shsk2s.azurecr.io' = @{
                    'auth' = "$token"
                }
            }
        }
    }
    else {
        $jsonConfig = @{
            '"auths"' = @{
                '"shsk2s.azurecr.io"' = @{
                    '"auth"' = """$token"""
                }
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    &$executeRemoteCommand "echo -e '$jsonString' | sudo tee /tmp/auth.json" | Out-Null
    &$executeRemoteCommand 'sudo mkdir -p /root/.config/containers'
    &$executeRemoteCommand 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'

    Write-Log 'Need to update registry conf file which is added as part of buildah installation'
    #&$executeRemoteCommand "sudo sed -i '/.*unqualified-search-registries.*/cunqualified-search-registries = [\\\""docker.io\\\"", \\\""quay.io\\\""]' /etc/containers/registries.conf"
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand 'sudo echo unqualified-search-registries = [\"docker.io\", \"quay.io\"] | sudo tee -a /etc/containers/registries.conf'
    }
    else {
        &$executeRemoteCommand 'sudo echo unqualified-search-registries = [\\\"docker.io\\\", \\\"quay.io\\\"] | sudo tee -a /etc/containers/registries.conf'
    }
    # restart crio after updating registry.conf
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'sudo systemctl restart crio'

    Write-Log 'Finished installing tools in Linux'

}

function Install-DnsServer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Install custom DNS server'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsutils --yes'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsmasq --yes'

    Write-Log 'Stop custom DNS server'
    &$executeRemoteCommand 'sudo systemctl stop dnsmasq'
}

function Get-FlannelImages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Get images used by flannel'
    &$executeRemoteCommand 'sudo crictl pull rancher/mirrored-flannelcni-flannel-cni-plugin:v1.1.0'
    &$executeRemoteCommand 'sudo crictl pull rancher/mirrored-flannelcni-flannel:v0.18.1'
}

function Set-Nameserver {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Set nameserver'
    # DNS
    &$executeRemoteCommand 'sudo chattr -i /etc/resolv.conf'
    &$executeRemoteCommand 'sudo rm -f /etc/resolv.conf'
    &$executeRemoteCommand 'echo nameserver 172.19.1.100 | sudo tee /etc/resolv.conf'
}

<#
.SYNOPSIS
Adds a configuration file that is used when creating the support for WSL integration.
.DESCRIPTION
Creates a configuration file populated with needed information that is used to support the integration into WSL.
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER IpAddress
The IP address of the VM.
#>
Function Add-SupportForWSL {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    # WSL2 config
    Write-Log 'Configure WSL2'
    &$executeRemoteCommand 'sudo touch /etc/wsl.conf'
    &$executeRemoteCommand 'echo [automount] | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo enabled = false | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand "echo -e 'mountFsTab = false\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand 'echo [interop] | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo enabled = false | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand "echo -e 'appendWindowsPath = false\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand 'echo [user] | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand "echo -e 'default = __USERNAME__\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand 'echo [network] | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo generateHosts = false | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo generateResolvConf = false | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo hostname = __HOSTNAME__ | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo | sudo tee -a /etc/wsl.conf'

    &$executeRemoteCommand 'echo [boot] | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand 'echo systemd = true | sudo tee -a /etc/wsl.conf'
    &$executeRemoteCommand "echo 'command = ""sudo ifconfig __INTERFACE_NAME__ __IP_ADDRESS__ && sudo ifconfig __INTERFACE_NAME__ netmask __NETWORK_MASK__"" && sudo route add default gw __GATEWAY_IP_ADDRESS__' | sudo tee -a /etc/wsl.conf"
}

function Edit-SupportForWSL {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$Hostname = $(throw 'Argument missing: Hostname'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$NetworkInterfaceName = $(throw 'Argument missing: NetworkInterfaceName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$NetworkMask = $(throw 'Argument missing: NetworkMask'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$GatewayIpAddress = $(throw 'Argument missing: GatewayIpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Edit WSL2 support'
    &$executeRemoteCommand "sudo sed -i `"s/__USERNAME__/$UserName/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__HOSTNAME__/$Hostname/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__IP_ADDRESS__/$IpAddress/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__INTERFACE_NAME__/$NetworkInterfaceName/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__NETWORK_MASK__/$NetworkMask/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__GATEWAY_IP_ADDRESS__/$GatewayIpAddress/g`" $wslConfigurationFilePath"
}

<#
.SYNOPSIS
Sets up a VM to act as master node.
.DESCRIPTION
An accessible VM with already installed Kubernetes artifacts is configured to act as master node.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER K8sVersion
The Kubernetes version to use.
.PARAMETER ClusterCIDR
The Kubernetes pod network CIDR.
.PARAMETER ClusterCIDR_Services
The Kubernetes service network CIDR.
.PARAMETER KubeDnsServiceIP
The IP address of the DNS service inside the Kubernetes cluster.
.PARAMETER IP_NextHop
The IP address of the Windows host reachable from the VM
.PARAMETER NetworkInterfaceName
The name of the network interface of the VM.
.PARAMETER NetworkInterfaceCni0IP_Master
The IP address of the the cni network interface in the VM.
.PARAMETER Hook
A script block that will get executed at the end of the set-up process (can be used for e.g. to install custom tools).
#>
Function Set-UpMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$NodeName = $(throw 'Argument missing: NodeName'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $ClusterCIDR = $(throw 'Argument missing: ClusterCIDR'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $ClusterCIDR_Services = $(throw 'Argument missing: ClusterCIDR_Services'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $KubeDnsServiceIP = $(throw 'Argument missing: KubeDnsServiceIP'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IP_NextHop = $(throw 'Argument missing: IP_NextHop'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $NetworkInterfaceName = $(throw 'Argument missing: NetworkInterfaceName'),
        [ScriptBlock] $Hook = $(throw 'Argument missing: Hook')
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false
        )
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        } else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
    }

    Write-Log "Start setting up computer '$IpAddress' as master node"

    &$executeRemoteCommand "sudo kubeadm init --kubernetes-version $K8sVersion --apiserver-advertise-address $IpAddress --pod-network-cidr=$ClusterCIDR --service-cidr=$ClusterCIDR_Services" -IgnoreErrors

    Write-Log 'Copy K8s config file to user profile'
    &$executeRemoteCommand 'mkdir -p ~/.kube'
    &$executeRemoteCommand 'chmod 755 ~/.kube'
    &$executeRemoteCommand 'sudo cp /etc/kubernetes/admin.conf ~/.kube/config'
    &$executeRemoteCommand "sudo chown $UserName ~/.kube/config"
    &$executeRemoteCommand 'kubectl get nodes'

    Write-Log 'Install custom DNS server'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsutils --yes'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsmasq --yes'

    Write-Log 'Scale down coredns to 1 replicas'
    &$executeRemoteCommand 'kubectl scale deployment coredns -n kube-system --replicas=1'

    Write-Log 'Configure custom DNS server'
    # add more interfaces to listen on
    &$executeRemoteCommand "echo server=/cluster.local/$KubeDnsServiceIP | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo server=$IP_NextHop@$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo interface=$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand 'echo interface=cni0 | sudo tee -a /etc/dnsmasq.conf'
    &$executeRemoteCommand 'echo interface=lo | sudo tee -a /etc/dnsmasq.conf'

    Write-Log 'Restart custom DNS server'
    &$executeRemoteCommand 'sudo systemctl restart dnsmasq'

    # import etcd certificates as k8s secrets, so that coredns can access etcd
    &$executeRemoteCommand 'sudo mkdir etcd'
    &$executeRemoteCommand 'sudo cp /etc/kubernetes/pki/etcd/* etcd/'
    &$executeRemoteCommand 'sudo chmod 444 etcd/*'
    &$executeRemoteCommand 'kubectl create secret -n kube-system tls etcd-ca --cert=etcd/ca.crt --key=etcd/ca.key'
    &$executeRemoteCommand 'kubectl create secret -n kube-system tls etcd-client-for-core-dns --cert=etcd/healthcheck-client.crt --key=etcd/healthcheck-client.key'
    &$executeRemoteCommand 'sudo rm -r etcd'

    # update coredns configmap kubernetes plugin to fallthrough for all zones
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed 's/fallthrough\ in-addr.arpa\ ip6.arpa/fallthrough/1' | kubectl apply -f -" -IgnoreErrors

    # change core-dns to serve the cluster.local zone from the etcd plugin as fallback
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*prometheus :9153/i\        etcd cluster.local {\n            path /skydns\n            endpoint https://${IpAddress}:2379\n            tls /etc/kubernetes/pki/etcd-client/tls.crt /etc/kubernetes/pki/etcd-client/tls.key /etc/kubernetes/pki/etcd-ca/tls.crt\n        }' | kubectl apply -f -" -IgnoreErrors

    # mount the certificate secrets in coredns, so it can read them
    &$executeRemoteCommand "kubectl get deployment coredns -n kube-system -o yaml | sed '/^\s*\- configMap:/i\      - name: etcd-ca-cert\n        secret:\n          secretName: etcd-ca\n      - name: etcd-client-cert\n        secret:\n          secretName: etcd-client-for-core-dns' | kubectl apply -f -" -IgnoreErrors
    &$executeRemoteCommand "kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=30s" -IgnoreErrors
    &$executeRemoteCommand "kubectl get deployment coredns -n kube-system -o yaml | sed '/^\s*\- mountPath: \/etc\/coredns/i\        - mountPath: /etc/kubernetes/pki/etcd-ca\n          name: etcd-ca-cert\n        - mountPath: /etc/kubernetes/pki/etcd-client\n          name: etcd-client-cert' | kubectl apply -f -" -IgnoreErrors

    # change core-dns to have predefined host mapping for DNS resolution
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*cache 30/i\        hosts {\n         $IpAddress k2s.cluster.local\n         fallthrough\n        }' | kubectl apply -f -" -IgnoreErrors

    Write-Log 'Initialize Flannel'
    Add-FlannelPluginToMasterNode -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -PodNetworkCIDR $ClusterCIDR

    $getPodCidrOutput = Get-AssignedPodNetworkCIDR -NodeName $NodeName -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    if ($getPodCidrOutput.Success) {
        $assignedPodNetworkCIDR = $($getPodCidrOutput.PodNetworkCIDR).Substring(0, $($getPodCidrOutput.PodNetworkCIDR).IndexOf('/'))
    } else {
        throw "Cannot obtain pod network information from node '$NodeName'"
    }
    $networkInterfaceCni0IP = "$($assignedPodNetworkCIDR.Substring(0, $assignedPodNetworkCIDR.lastIndexOf('.'))).1"

    Write-Log 'Add DNS resolution rules to K8s DNS component'
    # change config map to forward all non cluster DNS request to proxy (dnsmasq) running on master
    &$executeRemoteCommand "kubectl get configmap/coredns -n kube-system -o yaml | sed -e 's|forward . /etc/resolv.conf|forward . $networkInterfaceCni0IP|' | kubectl apply -f -" -IgnoreErrors


    Write-Log 'Run setup hook'
    &$Hook
    Write-Log 'Setup hook finished'

    Write-Log 'Redirect to localhost IP address for DNS resolution'
    &$executeRemoteCommand 'sudo chattr -i /etc/resolv.conf'
    &$executeRemoteCommand "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf"

    Write-Log 'Finished setting up Linux computer as master'
}

Function Set-UpWorkerNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ScriptBlock] $Hook = $(throw 'Argument missing: Hook')
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false
        )
        if ($IgnoreErrors) {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        }
    }

    Write-Log "Start setting up computer '$IpAddress' as worker node"

    Write-Log 'Run setup hook'
    &$Hook
    Write-Log 'Setup hook finished'

    Write-Log 'Finished setting up Linux computer for being used as worker node'
}

Function Add-FlannelPluginToMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $PodNetworkCIDR = $(throw 'Argument missing: PodNetworkCIDR')
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $fileName = 'flannel.yml'

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        } else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        }
    }

    $waitUntilContainerNetworkPluginIsRunning = {
        $iteration = 0
        while ($true) {
            $iteration++
            # try to apply the flannel resources
            $command = 'kubectl rollout status daemonset -n kube-flannel kube-flannel-ds --timeout 60s'
            if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
                $result = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$IgnoreErrors).Output
            } else {
                $result = (Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output
            }
            if ($result -match 'successfully') {
                break;
            }
            if ($iteration -eq 25) {
                Write-Log 'Flannel CNI could not be set up, aborting...'
                throw 'Unable to get the CNI plugin Flannel running !'
            }
            if ($iteration -ge 3 ) {
                Write-Log 'Flannel CNI not yet available, waiting for it...'
                $x3 = $iteration % 3 -eq 0
                if ( $x3 ) {
                    &$executeRemoteCommand 'sudo systemctl restart kubelet'
                }
                &$executeRemoteCommand "sudo kubectl apply -f ~/$fileName"
            }
            Start-Sleep 2
        }
        if ($iteration -eq 1) {
            Write-Log 'Flannel CNI running, no waiting needed'
        }
        else {
            Write-Log 'Flannel CNI now running correctly'
        }
    }

    Write-Log 'Change default forward policy'
    &$executeRemoteCommand 'sudo iptables --policy FORWARD ACCEPT'

    Write-Log 'Prepare Flannel configuration file'
    $NetworkAddress = "      ""Network"": ""$PodNetworkCIDR"","
    $NetworkName = '      "name": "cbr0",'
    $NetworkType = '        "Type": "host-gw"'

    $configurationFile = "$PSScriptRoot\containernetwork\masternode\$fileName"
    Copy-Item "$PSScriptRoot\containernetwork\masternode\flannel.template.yml" "$configurationFile" -Force
    $lineNetworkName = Get-Content "$configurationFile" | Select-String NETWORK.NAME | Select-Object -ExpandProperty Line
    if ( $lineNetworkName ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkName, $NetworkName } | Set-Content "$configurationFile"
    }
    $lineNetworkType = Get-Content "$configurationFile" | Select-String NETWORK.TYPE | Select-Object -ExpandProperty Line
    if ( $lineNetworkType ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkType, $NetworkType } | Set-Content "$configurationFile"
    }
    $lineNetworkAddress = Get-Content "$configurationFile" | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
    if ( $lineNetworkAddress ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content "$configurationFile"
    }
    Write-Log 'Copy Flannel configuration file to computer'
    $target = "/home/$UserName"
    if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
        Copy-ToRemoteComputerViaSshKey -Source "$configurationFile" -Target $target -UserName $UserName -IpAddress $IpAddress
    } else {
        Copy-ToRemoteComputerViaUserAndPwd -Source "$configurationFile" -Target $target -UserName $UserName -UserPwd $remoteUserPwd -IpAddress $IpAddress
    }

    Write-Log 'Apply flannel configuration file on computer'
    &$executeRemoteCommand "kubectl apply -f ~/$fileName"

    &$waitUntilContainerNetworkPluginIsRunning

}

<#
.SYNOPSIS
Sets up a Linux VM to be used as a cluster node.
.DESCRIPTION
Provisions a Linux VM with the needed Kubernetes artifacts in order to be used as a cluster node.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER K8sVersion
The CRI-O version to use.
.PARAMETER Proxy
The proxy to use.
#>
Function New-KubernetesNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion'),
        [string]$Proxy = ''
    )

    Assert-GeneralComputerPrequisites -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd

    Write-Log "Prepare the computer $IpAddress for provisioning"
    Set-UpComputerBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy

    Set-UpComputerWithSpecificOsBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished preparation of computer $IpAddress for provisioning"

    Write-Log "Start provisioning the computer $IpAddress"
    Install-KubernetesArtifacts -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy -K8sVersion $K8sVersion

    Write-Log "Finalize preparation of the computer $IpAddress after provisioning"
    Set-UpComputerWithSpecificOsAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log 'Linux VM is now prepared to be used as master node'

    Set-UpComputerAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished provisioning the computer $IpAddress"
}

function Get-KubenodeBaseFileName {
    return 'Kubenode-Base.vhdx'
}

function New-VmImageForKubernetesNode {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [string]$DnsIpAddresses = $(throw 'Argument missing: DnsIpAddresses'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize
    )

    $vmIpAddress = Get-VmIpForProvisioningKubeNode
    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode

    $setUpKubenode = {
        $addToKubeNode = {
            Install-DnsServer -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Install-Tools -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd -Proxy $Proxy
            Get-FlannelImages -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Add-SupportForWSL -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
        }

        $kubeNodeParameters = @{
            IpAddress  = $vmIpAddress
            UserName   = $vmUserName
            UserPwd    = $vmUserPwd
            Proxy      = $Proxy
            K8sVersion = $kubernetesVersion
        }

        New-KubernetesNode @kubeNodeParameters

        &$addToKubeNode
    }

    $kubenodeBaseImageCreationParams = @{
        Proxy                = $Proxy
        DnsIpAddresses       = $DnsIpAddresses
        Hook                 = $setUpKubenode
        OutputPath           = $VmImageOutputPath
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
    }

    New-KubenodeBaseImage @kubenodeBaseImageCreationParams
}

function New-VmImageForControlPlaneNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers = $(throw 'Argument missing: DnsServers'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageOutputPath)\$(Get-KubenodeBaseFileName)"

    $isKubenodeBaseImageAlreadyAvailable = (Test-Path $kubenodeBaseImagePath)
    $isOnlineInstallation = (!$isKubenodeBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isKubenodeBaseImageAlreadyAvailable) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            Proxy                = $Proxy
            DnsIpAddresses       = $DnsServers
            VmImageOutputPath    = $kubenodeBaseImagePath
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode
    $vmNetworkInterfaceName = Get-NetworkInterfaceName

    $setUpAsMasterNode = {
        $addToControlPlane = {
            $supportForWSLParams = @{
                UserName             = $vmUserName
                UserPwd              = $vmUserPwd
                Hostname             = $Hostname
                IpAddress            = $IpAddress
                NetworkInterfaceName = $(Get-NetworkInterfaceName)
                NetworkMask          = '255.255.255.0'
                GatewayIpAddress     = $GatewayIpAddress
            }
            Edit-SupportForWSL @supportForWSLParams
        }

        $masterNodeParams = @{
            NodeName                      = $Hostname
            IpAddress                     = $IpAddress
            UserName                      = $vmUserName
            UserPwd                       = $vmUserPwd
            K8sVersion                    = $kubernetesVersion
            ClusterCIDR                   = $(Get-ConfiguredClusterCIDR)
            ClusterCIDR_Services          = $(Get-ConfiguredClusterCIDRServices)
            KubeDnsServiceIP              = $(Get-ConfiguredKubeDnsServiceIP)
            IP_NextHop                    = $GatewayIpAddress
            NetworkInterfaceName          = $vmNetworkInterfaceName
            Hook                          = $addToControlPlane
        }
        Set-UpMasterNode @masterNodeParams
    }

    $kubemasterCreationParams = @{
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
        Hostname             = $Hostname
        IpAddress            = $IpAddress
        InterfaceName        = $vmNetworkInterfaceName
        DnsServers           = $DnsServers
        GatewayIpAddress     = $GatewayIpAddress
        InputPath            = $kubenodeBaseImagePath
        OutputPath           = $VmImageOutputPath
        Hook                 = $setUpAsMasterNode
    }
    New-KubemasterBaseImage @kubemasterCreationParams

    if ($DeleteFilesForOfflineInstallation) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }
}

function New-LinuxVmImageForWorkerNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers,
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageOutputPath)\$(Get-KubenodeBaseFileName)"

    $isKubenodeBaseImageAlreadyAvailable = (Test-Path $kubenodeBaseImagePath)
    $isOnlineInstallation = (!$isKubenodeBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isKubenodeBaseImageAlreadyAvailable) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            Proxy                = $Proxy
            DnsIpAddresses       = $DnsServers
            VmImageOutputPath    = $kubenodeBaseImagePath
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode
    $vmNetworkInterfaceName = Get-NetworkInterfaceName

    $remoteUser = "$vmUserName@$IpAddress"
    $remoteUserPwd = $vmUserPwd

    $setUpAsWorkerNode = {
        $executeInWorkerNode = {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo systemctl stop dnsmasq; sudo systemctl disable dnsmasq' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo chattr -i /etc/resolv.conf' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo nameserver $(Get-ConfiguredIPControlPlane) | sudo tee /etc/resolv.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
        }

        $workerNodeParams = @{
            IpAddress                     = $IpAddress
            UserName                      = $vmUserName
            UserPwd                       = $vmUserPwd
            Hook                          = $executeInWorkerNode
        }
        Set-UpWorkerNode @workerNodeParams
    }

    $kubeworkerCreationParams = @{
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
        Hostname             = $Hostname
        IpAddress            = $IpAddress
        InterfaceName        = $vmNetworkInterfaceName
        DnsServers           = $DnsServers
        GatewayIpAddress     = $GatewayIpAddress
        InputPath            = $kubenodeBaseImagePath
        OutputPath           = $VmImageOutputPath
        Hook                 = $setUpAsWorkerNode
    }
    New-KubeworkerBaseImage @kubeworkerCreationParams

    if ($DeleteFilesForOfflineInstallation) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

}

<#
.Description
CopyDotFile copy dot files for bash processing to master VM.
#>
function CopyDotFile($SourcePath, $DotFile,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd) {
    Write-Log "copying $SourcePath$DotFile to VM..."
    $source = "$SourcePath$DotFile"
    if (Test-Path($source)) {
        $target = "$DotFile.temp"
        $userName = $RemoteUser.Substring(0, $RemoteUser.IndexOf('@'))
        Copy-ToControlPlaneViaUserAndPwd -Source $source -Target $target
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sed 's/\r//g' $DotFile.temp > ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo chown -R $userName ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "rm $DotFile.temp" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
    }
}

<#
.Description
InstallAptPackages install apt package to master VM.
#>
function InstallAptPackages {
    param (
        [Parameter(Mandatory)]
        [string] $FriendlyName,
        [Parameter(Mandatory)]
        [string] $Packages,
        [Parameter(Mandatory = $false)]
        [string] $TestExecutable = '',
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $remoteUser = "$UserName@$IpAddress"

    Write-Log "installing needed apt packages for $FriendlyName..."
    $installCmd = "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes --allow-change-held-packages --fix-missing $Packages"
    $repairCmd = 'sudo apt --fix-broken install'
    if ([string]::IsNullOrWhiteSpace($UserPwd)) {
        (Invoke-CmdOnVmViaSSHKey $installCmd -Retries 2 -Timeout 2 -UserName $UserName -IpAddress $IpAddress -RepairCmd $repairCmd).Output | Write-Log
    } else {
        (Invoke-CmdOnControlPlaneViaUserAndPwd $installCmd -Retries 2 -Timeout 2 -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -RepairCmd $repairCmd).Output | Write-Log
    }

    if ($TestExecutable -ne '') {
        $testCmd = "which $TestExecutable"
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $exeInstalled = (Invoke-CmdOnVmViaSSHKey $testCmd -UserName $UserName -IpAddress $IpAddress).Output
        } else {
            $exeInstalled = (Invoke-CmdOnControlPlaneViaUserAndPwd $testCmd -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd").Output
        }
        if (!($exeInstalled -match "/bin/$TestExecutable")) {
            throw "'$FriendlyName' was not installed correctly"
        }
    }
}

<#
.Description
AddAptRepo add repository for apt in master VM.
#>
function AddAptRepo {
    param (
        [Parameter(Mandatory = $false)]
        [string]$RepoKeyUrl = '',
        [Parameter(Mandatory)]
        [string]$RepoDebString,
        [Parameter(Mandatory = $false)]
        [string]$ProxyApt = '',
        [Parameter(Mandatory = $false)]
        [string]$RemoteUser,
        [Parameter(Mandatory = $false)]
        [string]$RemoteUserPwd
    )
    Write-Log "adding apt-repository '$RepoDebString' with proxy '$ProxyApt' from '$RepoKeyUrl'"
    if ($RepoKeyUrl -ne '') {
        if ($ProxyApt -ne '') {
            (Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -s -k $RepoKeyUrl --proxy $ProxyApt | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -fsSL $RepoKeyUrl | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        }
        if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
    }
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo add-apt-repository '$RepoDebString' 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
    if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
}

function Import-SpecificDistroSettingsModule {
    param (
        [string] $ModulePath = $(throw 'Argument missing: ModulePath')
    )
    Import-Module $ModulePath
}

function Remove-VmImageForControlPlaneNode {
    Clear-ProvisioningArtifacts
}

function New-WslRootfsForControlPlaneNode {
    param (
        [string] $VmImageInputPath = $(throw 'Argument missing: VmImageInputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared rootfs file.')]
        [string] $RootfsFileOutputPath = $(throw 'Argument missing: RootfsFileOutputPath'),
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageInputPath)\$(Get-KubenodeBaseFileName)"

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            VmImageOutputPath    = $kubenodeBaseImagePath
            Proxy                = $Proxy
            VMDiskSize           = $VMDiskSize
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vhdxToRootfsCreationParams = @{
        KubenodeBaseImagePath = $kubenodeBaseImagePath
        SourceVhdxPath        = $VmImageInputPath
        TargetRootfsFilePath  = $RootfsFileOutputPath
        VMDiskSize            = $VMDiskSize
        VMMemoryStartupBytes  = $VMMemoryStartupBytes
        VMProcessorCount      = $VMProcessorCount
    }
    Convert-VhdxToRootfs @vhdxToRootfsCreationParams
}

function Set-ProxySettingsOnKubenode {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName')

    )

    Set-ProxySettingsForApt -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName
    Set-ProxySettingsForContainerRuntime -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName
    Set-ProxySettingsForContainers -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName

    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl daemon-reload' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
}

function Set-ProxySettingsForApt {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName')

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # packages
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for package tool'
        (Invoke-CmdOnVmViaSSHKey 'sudo rm -f /etc/apt/apt.conf.d/proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for package tool'
        (Invoke-CmdOnVmViaSSHKey 'sudo touch /etc/apt/apt.conf.d/proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            (Invoke-CmdOnVmViaSSHKey "echo Acquire::http::Proxy \""$ProxySettings\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
        else {
            (Invoke-CmdOnVmViaSSHKey "echo Acquire::http::Proxy \\\""$ProxySettings\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
    }
}

function Set-ProxySettingsForContainerRuntime {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName')

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # Container runtime
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for container runtime'
        (Invoke-CmdOnVmViaSSHKey 'sudo rm -fr /etc/systemd/system/crio.service.d' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for container runtime'
        (Invoke-CmdOnVmViaSSHKey 'sudo mkdir -p /etc/systemd/system/crio.service.d' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo [Service] | sudo tee /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'HTTP_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'HTTPS_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'http_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'https_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    }
}

function Set-ProxySettingsForContainers {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName')

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # Containers
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for containers'
        (Invoke-CmdOnVmViaSSHKey 'sudo rm -f /etc/containers/containers.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for containers'
        (Invoke-CmdOnVmViaSSHKey 'echo [engine] | sudo tee /etc/containers/containers.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            (Invoke-CmdOnVmViaSSHKey "echo env = [\""https_proxy=$ProxySettings\""] | sudo tee -a /etc/containers/containers.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
        else {
            (Invoke-CmdOnVmViaSSHKey "echo env = [\\\""https_proxy=$ProxySettings\\\""] | sudo tee -a /etc/containers/containers.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
    }
}

Export-ModuleMember -Function New-VmImageForControlPlaneNode,
New-LinuxVmImageForWorkerNode,
Remove-VmImageForControlPlaneNode,
Import-SpecificDistroSettingsModule,
New-WslRootfsForControlPlaneNode,
Set-ProxySettingsOnKubenode,
Get-KubenodeBaseFileName,
Install-KubernetesArtifacts,
Remove-KubernetesArtifacts
