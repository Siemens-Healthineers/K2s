
# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

$validationModule = "$PSScriptRoot\..\..\..\k2s.infra.module\validation\validation.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"

Import-Module $validationModule, $logModule, $vmModule, $configModule

Function Assert-GeneralComputerPrequisites {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log "Checking if the hostname contains only allowed characters..."
    [string]$hostname = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -NoLog
    if ([string]::IsNullOrWhiteSpace($hostname) -eq $true) {
        throw "The hostname of the computer with IP '$IpAddress' could not be retrieved."
    }

    #TODO Check the reason
    # $hasHostnameUppercaseChars = [regex]::IsMatch($hostname, "[^a-z]+")
    # if ($hasHostnameUppercaseChars) {
    #     throw "The hostname '$hostname' of the computer reachable on IP '$IpAddress' contains not allowed characters. " +
    #     "Only a hostname that follows the pattern [a-z] is allowed."
    # } else {
    #     Write-Log " ...done"
    # }
}

Function Assert-MasterNodeComputerPrequisites {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    [int]$numberOfCores = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'nproc' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -NoLog
    Write-Log "The computer with IP '$IpAddress' has $numberOfCores cores."
    if ($numberOfCores -lt 2) {
        throw "The computer reachable on IP '$IpAddress' does not has at least 2 cores"
    }
}

Function Set-UpComputerBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    if ( $Proxy -ne '' ) {
        Write-Log "Setting proxy '$Proxy' for apt"
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo touch /etc/apt/apt.conf.d/proxy.conf' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo Acquire::http::Proxy \""$Proxy\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
        } else {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo Acquire::http::Proxy \\\""$Proxy\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
        }
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
        Invoke-CmdOnControlPlaneViaUserAndPwd "sed 's/\r//g' $DotFile.temp > ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
        Invoke-CmdOnControlPlaneViaUserAndPwd "sudo chown -R $userName ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
        Invoke-CmdOnControlPlaneViaUserAndPwd "rm $DotFile.temp" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
    }
}

Function Set-UpComputerAfterProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log 'Copying some dotfiles to remote computer ...'
    CopyDotFile -SourcePath "$PSScriptRoot\dotfiles\" -DotFile '.inputrc' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\dotfiles\" -DotFile '.bash_kubectl' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\dotfiles\" -DotFile '.bash_docker' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\dotfiles\" -DotFile '.bash_aliases' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd

    Write-Log 'Set local time zone in VM...'
    $timezoneForVm = 'Europe/Berlin'
    Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo timedatectl set-timezone $timezoneForVm" -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd

    Write-Log 'Enable hushlogin...'
    Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'touch ~/.hushlogin' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
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
            Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -s -k $RepoKeyUrl --proxy $ProxyApt | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
        }
        else {
            Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -fsSL $RepoKeyUrl | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
        }
        if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
    }
    Invoke-CmdOnControlPlaneViaUserAndPwd "sudo add-apt-repository '$RepoDebString' 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd"
    if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
}

<#
.Description
InstallAptPackages install apt package to master VM.
#>
function InstallAptPackages {
    param (
        [Parameter(Mandatory)]
        [string]$FriendlyName,
        [Parameter(Mandatory)]
        [string]$Packages,
        [Parameter(Mandatory = $false)]
        [string]$TestExecutable = '',
        [Parameter(Mandatory = $false)]
        [string]$RemoteUser,
        [Parameter(Mandatory = $false)]
        [string]$RemoteUserPwd
    )
    Write-Log "installing needed apt packages for $FriendlyName..."
    Invoke-CmdOnControlPlaneViaUserAndPwd "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes --fix-missing $Packages" -Retries 2 -Timeout 2 -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -RepairCmd "sudo apt --fix-broken install"

    if ($TestExecutable -ne '') {
        $exeInstalled = $(Invoke-CmdOnControlPlaneViaUserAndPwd "which $TestExecutable" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd" -NoLog)
        if (!($exeInstalled -match "/bin/$TestExecutable")) {
            throw "'$FriendlyName' was not installed correctly"
        }
    }
}

Function Install-KubernetesArtifacts {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [string] $Proxy = '',
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $K8sVersion = $(throw "Argument missing: K8sVersion"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $CrioVersion = $(throw "Argument missing: CrioVersion")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw "Argument missing: Command"),
            [switch]$IgnoreErrors = $false,
            [string]$RepairCmd = $null, [uint16]$Retries = 0 )
        if ($IgnoreErrors) {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -IgnoreErrors
        } else {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -RepairCmd $RepairCmd
        }
    }

    Write-Log "Configure bridged traffic"
    &$executeRemoteCommand "echo overlay | sudo tee /etc/modules-load.d/k8s.conf"
    &$executeRemoteCommand "echo br_netfilter | sudo tee /etc/modules-load.d/k8s.conf"
    &$executeRemoteCommand "sudo modprobe overlay"
    &$executeRemoteCommand "sudo modprobe br_netfilter"

    &$executeRemoteCommand "echo net.bridge.bridge-nf-call-ip6tables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf"
    &$executeRemoteCommand "echo net.bridge.bridge-nf-call-iptables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf"
    &$executeRemoteCommand "echo net.ipv4.ip_forward = 1 | sudo tee -a /etc/sysctl.d/k8s.conf"
    &$executeRemoteCommand "sudo sysctl --system"

    &$executeRemoteCommand "echo @reboot root mount --make-rshared / | sudo tee /etc/cron.d/sharedmount"

    Write-Log "Download and install CRI-O"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change" -Retries 2 -RepairCmd "sudo apt --fix-broken install"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gpg" -Retries 2 -RepairCmd "sudo apt --fix-broken install"

    if ( $Proxy -ne '' ) {
        &$executeRemoteCommand "sudo curl --retry 3 --retry-connrefused -so cri-o.v$CrioVersion.tar.gz https://storage.googleapis.com/cri-o/artifacts/cri-o.amd64.v$CrioVersion.tar.gz --proxy $Proxy" -IgnoreErrors
    } else {
        &$executeRemoteCommand "sudo curl --retry 3 --retry-connrefused -so cri-o.v$CrioVersion.tar.gz https://storage.googleapis.com/cri-o/artifacts/cri-o.amd64.v$CrioVersion.tar.gz" -IgnoreErrors
    }
    &$executeRemoteCommand "sudo mkdir -p /usr/cri-o"
    &$executeRemoteCommand "sudo tar -xf cri-o.v$CrioVersion.tar.gz -C /usr/cri-o --strip-components=1"
    &$executeRemoteCommand 'cd /usr/cri-o/ && sudo ./install 2>&1'
    #Delete downloaded file
    &$executeRemoteCommand "sudo rm cri-o.v$CrioVersion.tar.gz"

    if ( $Proxy -ne '' ) {
        Write-Log "Set proxy to CRI-O"
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
            "auths" = @{
                "shsk2s.azurecr.io" = @{
                    "auth" = "$token"
                }
            }
        }
    } else {
        $jsonConfig = @{
            """auths""" = @{
                """shsk2s.azurecr.io""" = @{
                    """auth""" = """$token"""
                }
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    &$executeRemoteCommand "echo -e '$jsonString' | sudo tee /tmp/auth.json" | Out-Null
    &$executeRemoteCommand 'sudo mkdir -p /root/.config/containers'
    &$executeRemoteCommand 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'

    Write-Log "Configure CRI-O (part 1 of 2)"
    # cri-o default cni bridge should have least priority
    $CRIO_CNI_FILE = '/etc/cni/net.d/10-crio-bridge.conf'
    &$executeRemoteCommand "[ -f $CRIO_CNI_FILE ] && sudo mv $CRIO_CNI_FILE /etc/cni/net.d/100-crio-bridge.conf || echo File does not exist, no renaming of cni file $CRIO_CNI_FILE.."
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand "sudo echo unqualified-search-registries = [\""docker.io\""] | sudo tee -a /etc/containers/registries.conf"
    } else {
        &$executeRemoteCommand "sudo echo unqualified-search-registries = [\\\""docker.io\\\""] | sudo tee -a /etc/containers/registries.conf"
    }

    Write-Log "Install other depended-on tools"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes apt-transport-https ca-certificates curl" -Retries 2 -RepairCmd "sudo apt --fix-broken install"
    &$executeRemoteCommand "sudo apt-get update" -Retries 2 -RepairCmd "sudo apt --fix-broken install"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes apt-transport-https ca-certificates curl" -Retries 2 -RepairCmd "sudo apt --fix-broken install"

    Write-Log "Install kubetools (kubelet, kubeadm, kubectl)"
    $proxyToAdd = ""
    if($Proxy -ne '') {
        $proxyToAdd = " --Proxy $Proxy"
    }

    # we need major and minor for apt keys
    $pkgShortK8sVersion = $K8sVersion.Substring(0, $K8sVersion.lastIndexOf('.'))
    &$executeRemoteCommand "sudo curl --retry 3 --retry-connrefused -fsSL https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/Release.key$proxyToAdd | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg" -IgnoreErrors
    &$executeRemoteCommand "echo 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list"
    $shortKubeVers = ($K8sVersion -replace 'v', '') + '-1.1'

    &$executeRemoteCommand "sudo apt-get update"
    InstallAptPackages -FriendlyName 'kubernetes' -Packages "kubelet=$shortKubeVers kubeadm=$shortKubeVers kubectl=$shortKubeVers" -TestExecutable 'kubectl' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
    &$executeRemoteCommand "sudo apt-mark hold kubelet kubeadm kubectl"

    Write-Log "Configure CRI-O (part 2 of 2): adapt CRI-O config file to use pause image version specified by kubeadm"
    &$executeRemoteCommand "pauseImageToUse=`"`$(kubeadm config images list --kubernetes-version $K8sVersion | grep \`"pause\`")`" && newTextLine=`$(echo pause_image = '\`"'`$pauseImageToUse'\`"') && sudo sed -i \`"s#.*pause_image[ ]*=.*pause.*#`$newTextLine#\`" /etc/crio/crio.conf"

    Write-Log "Start CRI-O"
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'sudo systemctl enable crio' -IgnoreErrors
    &$executeRemoteCommand 'sudo systemctl start crio'

    Write-Log "Pull images used by K8s"
    &$executeRemoteCommand "sudo kubeadm config images pull --kubernetes-version $K8sVersion"
}

Function Install-Tools {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [string] $Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw "Argument missing: Command"), [string]$RepairCmd = $null, [string]$Retries = 0)
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -RepairCmd $RepairCmd
    }

    Write-Log "Start installing tools in the Linux VM"

    # INSTALL buildah FROM TESTING REPO IN ORDER TO GET A NEWER VERSION
    #################################################################################################################################################################
    Write-Log "Install container image creation tool: buildah"                                                                                                   #
    #First install buildah from latest debian bullseye                                                                                                              #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Options::="--force-confnew" install buildah --yes'                                   #
    #Remove chrony as it is unstable with latest version of buildah                                                                                                 #
    #&$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get remove chrony --yes'                                                                          #
                                                                                                                                                                    #
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes software-properties-common" -Retries 2 -RepairCmd "sudo apt --fix-broken install"                                                #
                                                                                                                                                                    #
    #Now update apt sources to get latest from bookworm                                                                                                              #
    AddAptRepo -RepoDebString 'deb http://deb.debian.org/debian bookworm main' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"                                        #
    AddAptRepo -RepoDebString 'deb http://deb.debian.org/debian-security/ bookworm-security main' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"                     #
                                                                                                                                                                    #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes' -Retries 2 -RepairCmd "sudo apt --fix-broken install"                                                                           #
    #&$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get remove chrony --yes'                                                                          #
                                                                                                                                                                    #
    #Install latest from bookworm now                                                                                                                                #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -t bookworm --no-install-recommends --no-install-suggests buildah --yes' -Retries 2 -RepairCmd "sudo apt --fix-broken install"            #
    &$executeRemoteCommand 'sudo buildah -v'                                                                                                                          #
                                                                                                                                                                    #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq --yes'                                                                         #
                                                                                                                                                                    #
    #Remove bookworm source now                                                                                                                                      #
    &$executeRemoteCommand "sudo apt-add-repository 'deb http://deb.debian.org/debian bookworm main' -r"                                                              #
    &$executeRemoteCommand "sudo apt-add-repository 'deb http://deb.debian.org/debian-security/ bookworm-security main' -r"                                           #
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes' -Retries 2 -RepairCmd "sudo apt --fix-broken install"                                                                          #
    #################################################################################################################################################################

    # Temporary fix for [master] not recognized in buildah 1.22.3, we comment the section as this is only specific to container engine
    # Issue is fixed in buildah 1.26 but exists in experimental stage
    #&$executeRemoteCommand "sudo sed -i 's/\[machine/#&/' /usr/share/containers/containers.conf"

    if($Proxy -ne '') {
        &$executeRemoteCommand "echo [engine] | sudo tee -a /etc/containers/containers.conf"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            &$executeRemoteCommand "echo env = [\""https_proxy=$Proxy\""] | sudo tee -a /etc/containers/containers.conf"
        } else {
            &$executeRemoteCommand "echo env = [\\\""https_proxy=$Proxy\\\""] | sudo tee -a /etc/containers/containers.conf"
        }
    }

    $token = Get-RegistryToken
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $jsonConfig = @{
            "auths" = @{
                "shsk2s.azurecr.io" = @{
                    "auth" = "$token"
                }
            }
        }
    } else {
        $jsonConfig = @{
            """auths""" = @{
                """shsk2s.azurecr.io""" = @{
                    """auth""" = """$token"""
                }
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    &$executeRemoteCommand "echo -e '$jsonString' | sudo tee /tmp/auth.json" | Out-Null
    &$executeRemoteCommand 'sudo mkdir -p /root/.config/containers'
    &$executeRemoteCommand 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'

    Write-Log "Need to update registry conf file which is added as part of buildah installation"
    #&$executeRemoteCommand "sudo sed -i '/.*unqualified-search-registries.*/cunqualified-search-registries = [\\\""docker.io\\\"", \\\""quay.io\\\""]' /etc/containers/registries.conf"
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        &$executeRemoteCommand "sudo echo unqualified-search-registries = [\""docker.io\"", \""quay.io\""] | sudo tee -a /etc/containers/registries.conf"
    } else {
        &$executeRemoteCommand "sudo echo unqualified-search-registries = [\\\""docker.io\\\"", \\\""quay.io\\\""] | sudo tee -a /etc/containers/registries.conf"
    }
    # restart crio after updating registry.conf
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'sudo systemctl restart crio'

    Write-Log "Finished installing tools in Linux"

}

Function Add-SupportForWSL {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NetworkInterfaceName = $(throw "Argument missing: NetworkInterfaceName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$GatewayIP = $(throw "Argument missing: GatewayIP")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw "Argument missing: Command"))
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
    }

    # WSL2 config
    Write-Log "Configure WSL2"
    &$executeRemoteCommand "sudo touch /etc/wsl.conf"
    &$executeRemoteCommand "echo [automount] | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo enabled = false | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo -e 'mountFsTab = false\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand "echo [interop] | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo enabled = false | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo -e 'appendWindowsPath = false\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand "echo [user] | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo -e 'default = $UserName\n' | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand "echo [network] | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo generateHosts = false | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo generateResolvConf = false | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo hostname = `$(hostname) | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo | sudo tee -a /etc/wsl.conf"

    &$executeRemoteCommand "echo [boot] | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo systemd = true | sudo tee -a /etc/wsl.conf"
    &$executeRemoteCommand "echo 'command = ""sudo ifconfig $NetworkInterfaceName $IpAddress && sudo ifconfig $NetworkInterfaceName netmask 255.255.255.0"" && sudo route add default gw $GatewayIP' | sudo tee -a /etc/wsl.conf"
}

Function Set-UpMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $K8sVersion = $(throw "Argument missing: K8sVersion"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $ClusterCIDR = $(throw "Argument missing: ClusterCIDR"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $ClusterCIDR_Services = $(throw "Argument missing: ClusterCIDR_Services"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $KubeDnsServiceIP = $(throw "Argument missing: KubeDnsServiceIP"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IP_NextHop = $(throw "Argument missing: IP_NextHop"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $NetworkInterfaceName = $(throw "Argument missing: NetworkInterfaceName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $NetworkInterfaceCni0IP_Master = $(throw "Argument missing: NetworkInterfaceCni0IP_Master"),
        [ScriptBlock] $Hook = $(throw "Argument missing: Hook")
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw "Argument missing: Command"),
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0)
        if ($IgnoreErrors) {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -IgnoreErrors
        } else {
            Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -RepairCmd $RepairCmd
        }
    }

    Write-Log "Start setting up computer '$IpAddress' as master node"

    &$executeRemoteCommand "sudo kubeadm init --kubernetes-version $K8sVersion --apiserver-advertise-address $IpAddress --pod-network-cidr=$ClusterCIDR --service-cidr=$ClusterCIDR_Services" -IgnoreErrors

    Write-Log "Copy K8s config file to user profile"
    &$executeRemoteCommand "mkdir -p ~/.kube"
    &$executeRemoteCommand "chmod 755 ~/.kube"
    &$executeRemoteCommand "sudo cp /etc/kubernetes/admin.conf ~/.kube/config"
    &$executeRemoteCommand "sudo chown $UserName ~/.kube/config"
    &$executeRemoteCommand 'kubectl get nodes'

    Write-Log "Install custom DNS server"
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsutils --yes' -Retries 2 -RepairCmd "sudo apt --fix-broken install"
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsmasq --yes' -Retries 2 -RepairCmd "sudo apt --fix-broken install"

    Write-Log "Configure custom DNS server"
    # add more interfaces to listen on
    &$executeRemoteCommand "echo server=/cluster.local/$KubeDnsServiceIP | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo server=$IP_NextHop@$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo interface=$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand 'echo interface=cni0 | sudo tee -a /etc/dnsmasq.conf'
    &$executeRemoteCommand 'echo interface=lo | sudo tee -a /etc/dnsmasq.conf'

    Write-Log "Restart custom DNS server"
    &$executeRemoteCommand 'sudo systemctl restart dnsmasq'

    Write-Log "Add DNS resolution rules to K8s DNS component"
    # change config map to forward all non cluster DNS request to proxy (dnsmasq) running on master
    &$executeRemoteCommand "kubectl get configmap/coredns -n kube-system -o yaml | sed -e 's|forward . /etc/resolv.conf|forward . $NetworkInterfaceCni0IP_Master|' | kubectl apply -f -" -IgnoreErrors

    Write-Log "Initialize Flannel"
    Add-FlannelPluginToMasterNode -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -PodNetworkCIDR $ClusterCIDR

    Write-Log "Run setup hook"
    &$Hook
    Write-Log "Setup hook finished"

    Write-Log "Redirect to localhost IP address for DNS resolution"
    &$executeRemoteCommand "sudo chattr -i /etc/resolv.conf"
    &$executeRemoteCommand "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf"

    Write-Log "Finished setting up Linux computer as master"

}

Function Add-FlannelPluginToMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $PodNetworkCIDR = $(throw "Argument missing: PodNetworkCIDR")
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $fileName = "flannel.yml"

    $executeRemoteCommand = { param($command = $(throw "Argument missing: Command"))
        Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd"
    }

    $waitUntilContainerNetworkPluginIsRunning = {
        $iteration = 0
        while ($true) {
            $iteration++
            # try to apply the flannel resources
            $result = Invoke-CmdOnControlPlaneViaUserAndPwd 'kubectl rollout status daemonset -n kube-flannel kube-flannel-ds --timeout 60s' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -NoLog
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

    Write-Log "Change default forward policy"
    &$executeRemoteCommand 'sudo iptables --policy FORWARD ACCEPT'

    Write-Log "Prepare Flannel configuration file"
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
    Write-Log "Copy Flannel configuration file to computer"
    $target = "/home/$UserName"
    Copy-ToControlPlaneViaUserAndPwd -Source "$configurationFile" -Target $target

    Write-Log "Apply flannel configuration file on computer"
    &$executeRemoteCommand "kubectl apply -f ~/$fileName"

    &$waitUntilContainerNetworkPluginIsRunning

}

Function New-KubernetesNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $K8sVersion = $(throw "Argument missing: K8sVersion"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $CrioVersion = $(throw "Argument missing: CrioVersion"),
        [string]$Proxy = ''
    )

    Assert-GeneralComputerPrequisites -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd

    Write-Log "Prepare the computer $IpAddress for provisioning"
    Set-UpComputerBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy

    Set-UpComputerWithSpecificOsBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished preparation of computer $IpAddress for provisioning"

    Write-Log "Start provisioning the computer $IpAddress"
    Install-KubernetesArtifacts -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy -K8sVersion $K8sVersion -CrioVersion $CrioVersion

    Write-Log "Finalize preparation of the computer $IpAddress after provisioning"
    Set-UpComputerWithSpecificOsAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Linux VM is now prepared to be used as master node"

    Set-UpComputerAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished provisioning the computer $IpAddress"
}

Function New-MasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [string]$Proxy = '',
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $K8sVersion = $(throw "Argument missing: K8sVersion"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $CrioVersion = $(throw "Argument missing: CrioVersion"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $ClusterCIDR = $(throw "Argument missing: ClusterCIDR"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $ClusterCIDR_Services = $(throw "Argument missing: ClusterCIDR_Services"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $KubeDnsServiceIP = $(throw "Argument missing: KubeDnsServiceIP"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $GatewayIP = $(throw "Argument missing: GatewayIP"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $NetworkInterfaceName = $(throw "Argument missing: NetworkInterfaceName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $NetworkInterfaceCni0IP_Master = $(throw "Argument missing: NetworkInterfaceCni0IP_Master"),

        [scriptblock]$Hook = $(throw "Argument missing: Hook")
    )

    Assert-MasterNodeComputerPrequisites -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd

    New-KubernetesNode -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -K8sVersion $K8sVersion -CrioVersion $CrioVersion -Proxy $Proxy

    $masterNodeParams = @{
        IpAddress=$IpAddress
        UserName=$userName
        UserPwd=$userPwd
        K8sVersion=$K8sVersion
        ClusterCIDR=$ClusterCIDR
        ClusterCIDR_Services=$ClusterCIDR_Services
        KubeDnsServiceIP=$KubeDnsServiceIP
        IP_NextHop=$GatewayIP
        NetworkInterfaceName=$NetworkInterfaceName
        NetworkInterfaceCni0IP_Master=$NetworkInterfaceCni0IP_Master
        Hook=$Hook
    }
    Set-UpMasterNode @masterNodeParams
}

Export-ModuleMember -Function Install-Tools, Add-SupportForWSL, Set-UpMasterNode, New-KubernetesNode, New-MasterNode