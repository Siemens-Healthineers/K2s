#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_WINDOWS_WORKER_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_WINDOWS_WORKER_SH_LOADED=1

readonly K2S_WINDOWS_WORKER_NAME='k2s-win-worker'
readonly K2S_WINDOWS_WORKER_NETWORK='k2s-switch'
readonly K2S_WINDOWS_WORKER_BRIDGE='kubeswitch'
readonly K2S_WINDOWS_WORKER_MAC='52:54:00:25:57:01'
readonly K2S_WINDOWS_WORKER_POD_SUBNET='172.20.1.0/24'

k2s_windows_worker_state_file() { printf '%s/windows-worker.json' "$K2S_CONFIG_DIR"; }
k2s_windows_worker_vm_dir() { printf '%s' '/var/lib/libvirt/images/k2s'; }
k2s_windows_worker_gateway() { k2s_cfg '.smallsetup.kubeSwitch'; }
k2s_windows_worker_network_cidr() { k2s_cfg '.smallsetup.masterNetworkCIDR'; }
k2s_windows_worker_ip() {
  local gateway
  gateway=$(k2s_windows_worker_gateway) || return 1
  printf '%s.101\n' "${gateway%.*}"
}

k2s_windows_worker_install_host_dependencies() {
  local package
  local packages='qemu-system-x86 qemu-utils util-linux libvirt-daemon-system libvirt-daemon-driver-qemu libvirt-daemon-config-network libvirt-clients dnsmasq-base ovmf openssh-client sshpass'
  k2s_log INFO 'Installing KVM Windows worker host dependencies.'
  k2s_wait_for_dpkg_lock || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get update || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get install -y $packages || return 1
  k2s_run systemd-sysusers || return 1
  for package in $packages; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq 'install ok installed'; then
      k2s_log ERROR "KVM Windows worker dependency was not installed: $package"
      return 1
    fi
  done
  k2s_windows_worker_start_libvirt
}

k2s_windows_worker_start_libvirt() {
  if systemctl cat libvirtd.service >/dev/null 2>&1; then
    k2s_run systemctl enable --now libvirtd || return 1
  elif systemctl cat virtqemud.socket >/dev/null 2>&1; then
    k2s_run systemctl enable --now virtqemud.socket || return 1
  elif systemctl cat virtqemud.service >/dev/null 2>&1; then
    k2s_run systemctl enable --now virtqemud || return 1
  else
    k2s_log ERROR 'Neither libvirtd.service, virtqemud.socket, nor virtqemud.service is available after libvirt installation.'
    return 1
  fi
  if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    k2s_log ERROR 'libvirt is installed but qemu:///system is unavailable. Check libvirtd or virtqemud logs.'
    return 1
  fi
}

k2s_windows_worker_memory_mb() {
  [[ "$K2S_WORKER_MEMORY" =~ ^([2-9]|[1-9][0-9]+)(GB|G)$ ]] || { k2s_log ERROR "Invalid --worker-memory value: $K2S_WORKER_MEMORY"; return 2; }
  printf '%s\n' "$(( ${BASH_REMATCH[1]} * 1024 ))"
}

k2s_windows_worker_disk_gb() {
  [[ "$K2S_WORKER_DISK_SIZE" =~ ^([2-9][0-9]|[1-9][0-9]{2,})(GB|G)$ ]] || { k2s_log ERROR "Invalid --worker-disk value: $K2S_WORKER_DISK_SIZE"; return 2; }
  printf '%s\n' "${BASH_REMATCH[1]}"
}

k2s_windows_worker_preflight() {
  local command memory_mb available_mb total_mb disk_gb available_gb
  [[ -r /dev/kvm && -c /dev/kvm ]] || { k2s_log ERROR 'KVM is unavailable. Enable nested virtualization and expose /dev/kvm to the Debian host.'; return 3; }
  for command in virsh qemu-img sfdisk ssh scp ssh-keyscan ssh-keygen sshpass sha256sum; do k2s_require_command "$command" || return 4; done
  getent passwd libvirt-qemu >/dev/null || { k2s_log ERROR 'The libvirt-qemu service account is missing. Reinstall libvirt-daemon-system.'; return 3; }
  getent passwd dnsmasq >/dev/null || { k2s_log ERROR 'The dnsmasq service account is missing. Install dnsmasq-base.'; return 3; }
  k2s_windows_worker_start_libvirt || return 3
  [[ "$K2S_WORKER_CPU_COUNT" =~ ^[1-9][0-9]*$ ]] || { k2s_log ERROR "Invalid --worker-cpus value: $K2S_WORKER_CPU_COUNT"; return 2; }
  memory_mb=$(k2s_windows_worker_memory_mb) || return $?
  disk_gb=$(k2s_windows_worker_disk_gb) || return $?
  available_mb=$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
  total_mb=$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  (( memory_mb * 4 <= total_mb * 3 )) || { k2s_log ERROR 'Windows worker memory must not exceed 75% of host memory.'; return 3; }
  (( available_mb >= memory_mb + 2048 )) || { k2s_log ERROR 'Windows worker would leave less than 2GB of host memory available.'; return 3; }
  available_gb=$(df -BG --output=avail "$K2S_CONFIG_DIR" | tail -1 | tr -dc '0-9')
  (( available_gb - disk_gb >= 20 )) || { k2s_log ERROR 'Windows worker would leave less than 20GB of host disk space available.'; return 3; }
}

k2s_windows_worker_network_create() {
  local gateway network_cidr worker_ip prefix network_xml result existing_xml
  gateway=$(k2s_windows_worker_gateway) || return 1
  network_cidr=$(k2s_windows_worker_network_cidr) || return 1
  worker_ip=$(k2s_windows_worker_ip) || return 1
  prefix=${network_cidr#*/}
  [[ "$prefix" == '24' ]] || { k2s_log ERROR "Managed KubeSwitch requires a /24 masterNetworkCIDR, found: $network_cidr"; return 2; }
  if virsh net-info "$K2S_WINDOWS_WORKER_NETWORK" >/dev/null 2>&1; then
    existing_xml=$(virsh net-dumpxml "$K2S_WINDOWS_WORKER_NETWORK") || return 1
    if ! printf '%s' "$existing_xml" | grep -Fq "bridge name='$K2S_WINDOWS_WORKER_BRIDGE'" || ! printf '%s' "$existing_xml" | grep -Fq "address='$gateway'"; then
      k2s_log INFO 'Replacing a prior K2s-managed libvirt network definition with the configured KubeSwitch network.'
      virsh net-destroy "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
      virsh net-undefine "$K2S_WINDOWS_WORKER_NETWORK" || return 1
    else
      virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
      virsh net-autostart "$K2S_WINDOWS_WORKER_NETWORK" || return 1
      ip route replace "$K2S_WINDOWS_WORKER_POD_SUBNET" via "$worker_ip"
      return 0
    fi
  fi
  network_xml=$(mktemp)
  cat > "$network_xml" <<EOF
<network><name>$K2S_WINDOWS_WORKER_NETWORK</name><forward mode='nat'/><bridge name='$K2S_WINDOWS_WORKER_BRIDGE' stp='on' delay='0'/><ip address='$gateway' netmask='255.255.255.0'><dhcp><range start='${gateway%.*}.100' end='${gateway%.*}.199'/><host mac='$K2S_WINDOWS_WORKER_MAC' name='$K2S_WINDOWS_WORKER_NAME' ip='$worker_ip'/></dhcp></ip></network>
EOF
  virsh net-define "$network_xml" && virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" && virsh net-autostart "$K2S_WINDOWS_WORKER_NETWORK"
  result=$?; rm -f "$network_xml"
  (( result == 0 )) || return "$result"
  ip route replace "$K2S_WINDOWS_WORKER_POD_SUBNET" via "$worker_ip"
}

k2s_windows_worker_prepare_image() {
  local vm_dir disk disk_gb
  vm_dir=$(k2s_windows_worker_vm_dir)
  disk="$vm_dir/$K2S_WINDOWS_WORKER_NAME.qcow2"
  disk_gb=$(k2s_windows_worker_disk_gb) || return $?
  install -d -m 0711 "$vm_dir" || return 1
  [[ ! -e "$disk" ]] || { printf '%s\n' "$disk"; return 0; }
  local cache="$vm_dir/WindowsWorker-Base.qcow2"
  if [[ -f "$cache" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$cache" "$disk" >&2 || return 1
  else
    k2s_windows_worker_import_qcow2 "$cache" >&2 || return $?
    qemu-img create -f qcow2 -F qcow2 -b "$cache" "$disk" >&2 || return 1
  fi
  printf '%s\n' "$disk"
}

k2s_windows_worker_import_qcow2() {
  local cache="$1" source_format temporary_cache
  [[ -f "$K2S_WINDOWS_QCOW2_PATH" ]] || { k2s_log ERROR 'A cached Windows worker base image or --windows-qcow2-path is required.'; return 2; }
  source_format=$(qemu-img info --output=json "$K2S_WINDOWS_QCOW2_PATH" | jq -r '.format') || return 1
  [[ "$source_format" == 'qcow2' ]] || { k2s_log ERROR "Windows worker image must use QCOW2 format, found: $source_format"; return 2; }
  temporary_cache="$cache.tmp"
  rm -f "$temporary_cache"
  k2s_log INFO "Importing prepared Windows worker QCOW2 image: $K2S_WINDOWS_QCOW2_PATH"
  qemu-img convert -f qcow2 -O qcow2 -o compat=1.1 "$K2S_WINDOWS_QCOW2_PATH" "$temporary_cache" || return 1
  qemu-img check "$temporary_cache" || { rm -f "$temporary_cache"; return 1; }
  chmod 0644 "$temporary_cache" || { rm -f "$temporary_cache"; return 1; }
  mv "$temporary_cache" "$cache"
}

k2s_windows_worker_detect_boot_mode() {
  local disk="$1" partition_table boot_sector
  boot_sector=$(mktemp) || return 1
  # A GPT header resides at LBA 1, while the MBR is at LBA 0. Copying 2 MiB
  # gives sfdisk both headers without attaching an NBD device to this nested VM.
  qemu-img dd -f qcow2 "if=$disk" "of=$boot_sector" bs=1M count=2 >/dev/null 2>&1 || { rm -f "$boot_sector"; return 1; }
  partition_table=$(sfdisk --json "$boot_sector" 2>/dev/null | jq -r '.partitiontable.label // empty')
  rm -f "$boot_sector"
  case "$partition_table" in
    dos)
      k2s_log INFO 'Detected MBR partition table; booting the Windows worker with BIOS.'
      printf '%s\n' bios
      ;;
    gpt)
      k2s_log INFO 'Detected GPT partition table; booting the Windows worker with UEFI.'
      printf '%s\n' uefi
      ;;
    *)
      k2s_log ERROR "Cannot detect a supported Windows worker partition table (found: ${partition_table:-none})."
      return 2
      ;;
  esac
}

k2s_windows_worker_ssh_dir() { printf '%s/ssh' "$K2S_CONFIG_DIR"; }
k2s_windows_worker_private_key() { printf '%s/windows-worker' "$(k2s_windows_worker_ssh_dir)"; }
k2s_windows_worker_known_hosts() { printf '%s/windows-worker.known_hosts' "$(k2s_windows_worker_ssh_dir)"; }

k2s_windows_worker_create_ssh_key() {
  local key_dir key
  key_dir=$(k2s_windows_worker_ssh_dir); key=$(k2s_windows_worker_private_key)
  mkdir -p "$key_dir"; chmod 700 "$key_dir"
  [[ -f "$key" && -f "$key.pub" ]] || ssh-keygen -q -t ed25519 -N '' -f "$key" -C k2s-windows-worker
  chmod 600 "$key"; chmod 644 "$key.pub"
}

k2s_windows_worker_create_bootstrap_media() {
  local stage media vm_dir admin_password public_key
  vm_dir=$(k2s_windows_worker_vm_dir)
  install -d -m 0711 "$vm_dir" || return 1
  stage=$(mktemp -d); media="$vm_dir/windows-worker-bootstrap.iso"
  admin_password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  public_key=$(cat "$(k2s_windows_worker_private_key).pub")
  mkdir -p "$stage/k2s"
  cp -a "$K2S_INSTALL_DIR/cfg" "$K2S_INSTALL_DIR/lib" "$K2S_INSTALL_DIR/smallsetup" "$stage/k2s/" || { rm -rf "$stage"; return 1; }
  if [[ -d "$K2S_INSTALL_DIR/bin" ]]; then
    tar -C "$K2S_INSTALL_DIR" --exclude='bin/*.iso' --exclude='bin/*.qcow2' --exclude='bin/*.vhdx' -cf - bin | tar -C "$stage/k2s" -xf - || { rm -rf "$stage"; return 1; }
  fi
  cat > "$stage/bootstrap.ps1" <<'EOF'
$ErrorActionPreference = 'Stop'
$bootstrapVolume = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'K2SBOOT' } | Select-Object -First 1
if ($null -eq $bootstrapVolume -or [string]::IsNullOrWhiteSpace($bootstrapVolume.DriveLetter)) { throw 'K2S bootstrap media is unavailable.' }
$source = "$($bootstrapVolume.DriveLetter):\k2s"
New-Item -ItemType Directory -Path 'C:\k2s' -Force | Out-Null
Copy-Item -Path "$source\*" -Destination 'C:\k2s' -Recurse -Force
$password = ConvertTo-SecureString -String (New-Guid).Guid -AsPlainText -Force
if (-not (Get-LocalUser -Name remote -ErrorAction SilentlyContinue)) { New-LocalUser -Name remote -Password $password -PasswordNeverExpires | Out-Null }
netsh winhttp set proxy '@KUBESWITCH_PROXY@' | Out-Null
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -DisplayName 'K2s OpenSSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path 'C:\Users\remote\.ssh' -Force | Out-Null
Set-Content -Path 'C:\Users\remote\.ssh\authorized_keys' -Value '@SSH_PUBLIC_KEY@' -NoNewline
icacls 'C:\Users\remote\.ssh' /inheritance:r /grant 'remote:(OI)(CI)F' | Out-Null
icacls 'C:\Users\remote\.ssh\authorized_keys' /inheritance:r /grant 'remote:F' | Out-Null
New-Item -ItemType Directory -Path 'C:\ProgramData\K2s' -Force | Out-Null
Set-Content -Path 'C:\ProgramData\K2s\windows-worker-bootstrap-ready' -Value 'ready' -NoNewline
Stop-Computer -Force
EOF
  sed -i "s|@SSH_PUBLIC_KEY@|$public_key|" "$stage/bootstrap.ps1"
  sed -i "s|@KUBESWITCH_PROXY@|$(k2s_windows_worker_gateway):8181|" "$stage/bootstrap.ps1"
  cat > "$stage/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><settings pass="windowsPE"><component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><UserData><AcceptEula>true</AcceptEula><FullName>K2s</FullName><Organization>Siemens Healthineers</Organization></UserData><DiskConfiguration><Disk wcm:action="add" wcm:keyValue="1"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition><CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions><ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions></Disk></DiskConfiguration><ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom></OSImage></ImageInstall></component></settings><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>$K2S_WINDOWS_WORKER_NAME</ComputerName><AutoLogon><Password><Value>$admin_password</Value><PlainText>true</PlainText></Password><Username>Administrator</Username><Enabled>true</Enabled><LogonCount>1</LogonCount></AutoLogon><UserAccounts><AdministratorPassword><Value>$admin_password</Value><PlainText>true</PlainText></Password></UserAccounts><OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><ProtectYourPC>3</ProtectYourPC></OOBE><FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command &quot;&amp; { \$v = Get-Volume | Where-Object { \$_.FileSystemLabel -eq 'K2SBOOT' } | Select-Object -First 1; &amp; &quot;&quot;\$(\$v.DriveLetter):\bootstrap.ps1&quot;&quot; }&quot;</CommandLine><Description>K2s worker bootstrap</Description></SynchronousCommand></FirstLogonCommands></component></settings></unattend>
EOF
  xorriso -as mkisofs -quiet -J -R -V K2SBOOT -o "$media" "$stage" || { rm -rf "$stage"; return 1; }
  chmod 0644 "$media"; rm -rf "$stage"
}

# The prepared QCOW2 already contains Windows and K2s bootstrap logic. It only
# needs the per-install public key, delivered as a small read-only config drive.
k2s_windows_worker_create_bootstrap_media() {
  local stage media vm_dir public_key
  vm_dir=$(k2s_windows_worker_vm_dir)
  install -d -m 0711 "$vm_dir" || return 1
  stage=$(mktemp -d) || return 1
  media="$vm_dir/windows-worker-bootstrap.iso"
  public_key=$(cat "$(k2s_windows_worker_private_key).pub") || { rm -rf "$stage"; return 1; }
  printf '%s\n' "$public_key" > "$stage/windows-worker.pub"
  xorriso -as mkisofs -quiet -J -R -V K2SBOOT -o "$media" "$stage" || { rm -rf "$stage"; return 1; }
  chmod 0644 "$media"
  rm -rf "$stage"
  printf '%s\n' "$media"
}

k2s_windows_worker_wait_for_shutdown() {
  local deadline=$((SECONDS + 2400))
  while [[ $(virsh domstate "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null) != 'shut off' ]]; do
    (( SECONDS < deadline )) || { k2s_log ERROR 'Timed out waiting for Windows worker base-image bootstrap.'; return 1; }
    sleep 10
  done
}

k2s_windows_worker_ssh() {
  ssh -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" -o ConnectTimeout=10 "remote@$(k2s_windows_worker_ip)" "$@"
}

k2s_windows_worker_password() { printf '%s' "${K2S_WINDOWS_WORKER_PASSWORD:-admin}"; }

k2s_windows_worker_password_ssh() {
  SSHPASS=$(k2s_windows_worker_password) sshpass -e ssh -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" -o ConnectTimeout=10 "remote@$(k2s_windows_worker_ip)" "$@"
}

k2s_windows_worker_password_scp() {
  SSHPASS=$(k2s_windows_worker_password) sshpass -e scp -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$(k2s_windows_worker_private_key).pub" "remote@$(k2s_windows_worker_ip):windows-worker.pub"
}

k2s_windows_worker_bootstrap_ssh_key() {
  k2s_log INFO 'Installing the generated Windows worker SSH key through temporary password authentication.'
  k2s_windows_worker_password_scp || return $?
  k2s_windows_worker_password_ssh 'powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Path C:\Users\remote\.ssh -Force | Out-Null; Copy-Item -Path C:\Users\remote\windows-worker.pub -Destination C:\Users\remote\.ssh\authorized_keys -Force; icacls C:\Users\remote\.ssh /inheritance:r /grant \"remote:(OI)(CI)F\" | Out-Null; icacls C:\Users\remote\.ssh\authorized_keys /inheritance:r /grant \"remote:F\" | Out-Null; Remove-Item C:\Users\remote\windows-worker.pub -Force; Restart-Service sshd"'
}

k2s_windows_worker_wait_for_ssh() {
  local known_hosts worker_ip deadline=$((SECONDS + 900))
  k2s_windows_worker_create_ssh_key || return 1
  known_hosts=$(k2s_windows_worker_known_hosts)
  worker_ip=$(k2s_windows_worker_ip) || return 1
  install -d -m 0700 "$(k2s_windows_worker_ssh_dir)" || return 1
  : > "$known_hosts"; chmod 600 "$known_hosts"
  while ! ssh-keyscan -T 10 -H "$worker_ip" >> "$known_hosts" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      k2s_windows_worker_log_ssh_diagnostics "$worker_ip"
      k2s_log ERROR 'Timed out waiting for Windows worker SSH host key.'
      return 1
    fi
    sleep 10
  done
  k2s_windows_worker_bootstrap_ssh_key || return $?
  while ! k2s_windows_worker_ssh 'exit 0'; do
    if (( SECONDS >= deadline )); then
      k2s_windows_worker_log_ssh_diagnostics "$worker_ip"
      k2s_log ERROR 'Timed out waiting for Windows worker SSH key authentication.'
      return 1
    fi
    sleep 10
  done
}

k2s_windows_worker_log_ssh_diagnostics() {
  local worker_ip="$1"
  k2s_log ERROR "Windows worker SSH diagnostics for $worker_ip"
  virsh domstate "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh dominfo "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh domifaddr "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh net-dhcp-leases "$K2S_WINDOWS_WORKER_NETWORK" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  ip -4 neigh show "$worker_ip" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh vncdisplay "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  if virsh screenshot "$K2S_WINDOWS_WORKER_NAME" "$K2S_CONFIG_DIR/${K2S_WINDOWS_WORKER_NAME}-console.png" >/dev/null 2>&1; then
    k2s_log ERROR "Windows worker console screenshot: $K2S_CONFIG_DIR/${K2S_WINDOWS_WORKER_NAME}-console.png"
  fi
  tail -n 100 "/var/log/libvirt/qemu/${K2S_WINDOWS_WORKER_NAME}.log" 2>&1 | tee -a "$K2S_LOG_FILE" || true
}

k2s_windows_worker_join_cluster() {
  local join_command join_script escaped_join gateway
  join_command=$(kubeadm token create --ttl 30m --print-join-command) || return 1
  escaped_join=${join_command//\'/\'\'}
  gateway=$(k2s_windows_worker_gateway) || return 1
  join_script=$(mktemp)
  cat > "$join_script" <<EOF
\$ErrorActionPreference = 'Stop'
Set-Location 'C:\\k2s'
Import-Module 'C:\\k2s\\lib\\modules\\windows\\infra\\k2s.infra.module\\k2s.infra.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\node\\k2s.node.module\\k2s.node.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\cluster\\k2s.cluster.module\\k2s.cluster.module.psm1' -Force
Initialize-Logging
\$kubernetesVersion = Get-DefaultK8sVersion
Initialize-WinNode -KubernetesVersion \$kubernetesVersion -HostGW:\$true -Proxy 'http://$gateway:8181' -PodSubnetworkNumber '1'
Initialize-KubernetesCluster -PodSubnetworkNumber '1' -JoinCommand '$escaped_join'
EOF
  scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$join_script" "remote@$(k2s_windows_worker_ip):C:/ProgramData/K2s/JoinWorker.ps1"
  local result=$?; rm -f "$join_script"; (( result == 0 )) || return "$result"
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\K2s\JoinWorker.ps1'
}

k2s_windows_worker_wait_for_node() {
  local deadline=$((SECONDS + 1200))
  while ! k2s_kubectl get node "$K2S_WINDOWS_WORKER_NAME" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { k2s_log ERROR 'Timed out waiting for the Windows worker Kubernetes node.'; return 1; }
    sleep 10
  done
  k2s_kubectl wait --for=condition=Ready "node/$K2S_WINDOWS_WORKER_NAME" --timeout=10m
}

k2s_windows_worker_define() {
  local disk="$1" memory_mb domain_xml boot_mode firmware variables nvram firmware_xml
  memory_mb=$(k2s_windows_worker_memory_mb) || return $?
  boot_mode=$(k2s_windows_worker_detect_boot_mode "$disk") || return $?
  firmware_xml=''
  if [[ "$boot_mode" == uefi ]]; then
    firmware=/usr/share/OVMF/OVMF_CODE_4M.fd
    variables=/usr/share/OVMF/OVMF_VARS_4M.fd
    [[ -r "$firmware" && -r "$variables" ]] || { k2s_log ERROR 'UEFI boot requires standard OVMF firmware and variables from the ovmf package.'; return 1; }
    nvram="/var/lib/libvirt/qemu/nvram/${K2S_WINDOWS_WORKER_NAME}_VARS.fd"
    firmware_xml="<loader readonly='yes' secure='no' type='pflash'>$firmware</loader><nvram template='$variables'>$nvram</nvram>"
  fi
  domain_xml=$(mktemp)
  cat > "$domain_xml" <<EOF
<domain type='kvm'><name>$K2S_WINDOWS_WORKER_NAME</name><memory unit='MiB'>$memory_mb</memory><currentMemory unit='MiB'>$memory_mb</currentMemory><vcpu placement='static'>$K2S_WORKER_CPU_COUNT</vcpu><os><type arch='x86_64' machine='q35'>hvm</type>$firmware_xml<boot dev='hd'/></os><features><acpi/><apic/><hyperv mode='custom'><relaxed state='on'/><vapic state='on'/><spinlocks state='on' retries='8191'/><vpindex state='on'/><runtime state='on'/><synic state='on'/><stimer state='on'/></hyperv></features><cpu mode='host-passthrough' check='none'/><clock offset='localtime'><timer name='hypervclock' present='yes'/><timer name='hpet' present='no'/></clock><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2' discard='unmap'/><source file='$disk'/><target dev='sda' bus='sata'/></disk><interface type='network'><mac address='$K2S_WINDOWS_WORKER_MAC'/><source network='$K2S_WINDOWS_WORKER_NETWORK'/><model type='e1000'/></interface><serial type='pty'/><console type='pty'/><graphics type='vnc' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics><video><model type='vga' vram='16384' heads='1' primary='yes'/></video><rng model='virtio'><backend model='random'>/dev/urandom</backend></rng><memballoon model='virtio'/></devices></domain>
EOF
  virsh define "$domain_xml"; local result=$?; rm -f "$domain_xml"; return "$result"
}

k2s_windows_worker_write_state() {
  local disk="$1" state gateway worker_ip
  state=$(k2s_windows_worker_state_file)
  gateway=$(k2s_windows_worker_gateway) || return 1
  worker_ip=$(k2s_windows_worker_ip) || return 1
  jq -n --arg name "$K2S_WINDOWS_WORKER_NAME" --arg network "$K2S_WINDOWS_WORKER_NETWORK" --arg ip "$worker_ip" --arg mac "$K2S_WINDOWS_WORKER_MAC" --arg disk "$disk" --arg proxy "http://$gateway:8181" '{name:$name,network:$network,ip:$ip,mac:$mac,disk:$disk,proxy:$proxy}' > "$state"
  chmod 600 "$state"
}

k2s_windows_worker_provision() {
  k2s_log INFO 'Preflighting managed KVM Windows worker.'
  k2s_windows_worker_preflight || return $?
  k2s_windows_worker_network_create || return 1
  local disk
  disk=$(k2s_windows_worker_prepare_image) || return $?
  k2s_windows_worker_create_ssh_key || return 1
  k2s_windows_worker_define "$disk" || return 1
  k2s_windows_worker_write_state "$disk" || return 1
  virsh start "$K2S_WINDOWS_WORKER_NAME" || return 1
  k2s_windows_worker_wait_for_ssh || return $?
  k2s_windows_worker_join_cluster || return $?
  k2s_windows_worker_wait_for_node || return $?
  k2s_log INFO 'Managed Windows worker is reachable through SSH and joined to the Kubernetes cluster.'
}

k2s_windows_worker_start() { virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true; virsh start "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true; }
k2s_windows_worker_stop() { virsh shutdown "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true; }
k2s_windows_worker_remove() {
  local vm_dir
  vm_dir=$(k2s_windows_worker_vm_dir)
  ip route del "$K2S_WINDOWS_WORKER_POD_SUBNET" 2>/dev/null || true
  virsh destroy "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true
  virsh undefine "$K2S_WINDOWS_WORKER_NAME" --remove-all-storage --nvram 2>/dev/null || true
  rm -f "$vm_dir/$K2S_WINDOWS_WORKER_NAME.qcow2" "$vm_dir/${K2S_WINDOWS_WORKER_NAME}_VARS.fd" "$vm_dir/windows-worker-bootstrap.iso"
  virsh net-destroy "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
  virsh net-undefine "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
  rm -f "$(k2s_windows_worker_state_file)"
}