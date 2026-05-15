// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/config"
)

const (
	flannelTemplateRelPath = "lib/modules/k2s/k2s.node.module/linuxnode/distros/containernetwork/masternode/flannel.template.yml"
	podNetworkCIDR         = "172.20.0.0/16"
	servicesCIDR           = "172.21.0.0/16"
	clusterDNS             = "172.21.0.10"
	flannelNetworkName     = "cbr0"
	flannelBackendType     = "vxlan"
	kubeconfigSrc          = "/etc/kubernetes/admin.conf"
	winVMName              = "k2s-win-worker"
)

// LinuxOrchestrator implements Orchestrator using native Linux tools:
// kubeadm, systemctl, and libvirt for managing a Windows worker VM.
type LinuxOrchestrator struct{}

// NewOrchestrator returns the platform-specific orchestrator.
// On Linux, it returns a native kubeadm/systemd/libvirt orchestrator.
func NewOrchestrator(_ interface{}) Orchestrator {
	return &LinuxOrchestrator{}
}

func (o *LinuxOrchestrator) Install(cfg InstallConfig) error {
	slog.Info("[Install] Installing K2s on Linux host", "linuxOnly", cfg.LinuxOnly)

	// Step 1: Check prerequisites
	if err := o.checkPrerequisites(cfg); err != nil {
		return fmt.Errorf("prerequisite check failed: %w", err)
	}

	// Step 2: Install control plane natively via kubeadm
	if err := o.installControlPlane(cfg); err != nil {
		return fmt.Errorf("failed to install control plane: %w", err)
	}

	// Step 3: Set up kubeconfig for current user
	if err := o.setupKubeconfig(); err != nil {
		return fmt.Errorf("failed to setup kubeconfig: %w", err)
	}

	// Step 4: Deploy flannel CNI
	if err := o.deployFlannel(cfg); err != nil {
		return fmt.Errorf("failed to deploy flannel: %w", err)
	}

	// Step 5: Wait for control plane node to be Ready
	if err := o.waitForNodeReady(120 * time.Second); err != nil {
		slog.Warn("[Install] Control plane node not ready yet (may take a moment)", "error", err)
	}

	// Step 6: Persist setup.json
	hostname, _ := os.Hostname()
	clusterName := cfg.ClusterName
	if clusterName == "" {
		clusterName = "k2s-cluster"
	}
	if err := config.WriteRuntimeConfig(cfg.ConfigDir, "k2s", cfg.LinuxOnly, cfg.Version, clusterName, hostname, false); err != nil {
		return fmt.Errorf("failed to write runtime config: %w", err)
	}

	if !cfg.LinuxOnly {
		// Step 7: Create and provision Windows worker VM (Phase 3 — future)
		if err := o.provisionWindowsVM(cfg); err != nil {
			return fmt.Errorf("failed to provision Windows VM: %w", err)
		}
	}

	slog.Info("[Install] K2s installation complete")
	return nil
}

func (o *LinuxOrchestrator) Uninstall(cfg UninstallConfig) error {
	slog.Info("[Uninstall] Uninstalling K2s from Linux host")

	// Stop and remove Windows VM if it exists
	_ = runCommand("virsh", "destroy", winVMName)
	_ = runCommand("virsh", "undefine", winVMName, "--remove-all-storage", "--nvram")

	// Remove K2s libvirt network
	if err := RemoveK2sNetwork(); err != nil {
		slog.Warn("[Uninstall] Could not remove K2s network (may not exist)", "error", err)
	}

	// Reset kubeadm
	if !cfg.SkipPurge {
		if err := runCommand("kubeadm", "reset", "-f"); err != nil {
			slog.Warn("[Uninstall] kubeadm reset failed (may already be clean)", "error", err)
		}

		o.cleanupCriOMirrorDropIns()
	}

	// Clean up network interfaces created by flannel
	_ = runCommand("ip", "link", "delete", "cni0")
	_ = runCommand("ip", "link", "delete", "flannel.1")

	// Clean up iptables rules left by kube-proxy / flannel
	_ = runCommand("iptables", "-F")
	_ = runCommand("iptables", "-t", "nat", "-F")
	_ = runCommand("iptables", "-t", "mangle", "-F")
	_ = runCommand("iptables", "-X")

	// Remove kubeconfig
	if u, err := user.Current(); err == nil {
		kubeconfigPath := filepath.Join(u.HomeDir, ".kube", "config")
		if err := os.Remove(kubeconfigPath); err != nil && !os.IsNotExist(err) {
			slog.Warn("[Uninstall] Could not remove kubeconfig", "path", kubeconfigPath, "error", err)
		}
	}

	// Remove setup.json
	if cfg.ConfigDir != "" {
		if err := os.RemoveAll(cfg.ConfigDir); err != nil {
			slog.Warn("[Uninstall] Could not remove config dir", "path", cfg.ConfigDir, "error", err)
		}
	}

	slog.Info("[Uninstall] K2s uninstallation complete")
	return nil
}

func (o *LinuxOrchestrator) cleanupCriOMirrorDropIns() {
	removedAny := false

	configPaths, err := filepath.Glob("/etc/containers/registries.conf.d/*.conf")
	if err != nil {
		slog.Warn("[Uninstall] Could not enumerate CRI-O registry configs", "error", err)
		return
	}

	for _, configPath := range configPaths {
		content, err := os.ReadFile(configPath)
		if err != nil {
			if !os.IsNotExist(err) {
				slog.Warn("[Uninstall] Could not read CRI-O registry config", "path", configPath, "error", err)
			}
			continue
		}

		if !strings.Contains(string(content), "[[registry.mirror]]") {
			continue
		}

		if err := os.Remove(configPath); err != nil {
			if !os.IsNotExist(err) {
				slog.Warn("[Uninstall] Could not remove CRI-O registry mirror config", "path", configPath, "error", err)
			}
			continue
		}

		removedAny = true
		slog.Info("[Uninstall] Removed CRI-O registry mirror config", "path", configPath)
	}

	if !removedAny {
		return
	}

	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		slog.Warn("[Uninstall] Could not reload systemd after CRI-O registry mirror cleanup", "error", err)
	}

	if err := runCommand("systemctl", "is-active", "--quiet", "crio"); err == nil {
		if err := runCommand("systemctl", "restart", "crio"); err != nil {
			slog.Warn("[Uninstall] Could not restart CRI-O after registry mirror cleanup", "error", err)
		}
	}
}

func (o *LinuxOrchestrator) Start(cfg StartConfig) error {
	slog.Info("[Start] Starting K2s cluster on Linux host")

	// Start kubelet — control plane static pods come up automatically
	if err := runCommand("systemctl", "start", "kubelet"); err != nil {
		return fmt.Errorf("failed to start kubelet: %w", err)
	}

	// Start Windows VM if it exists
	vmManager := NewVMManager()
	if exists, _ := vmManager.VMExists(winVMName); exists {
		if err := vmManager.StartVM(winVMName); err != nil {
			slog.Warn("[Start] Could not start Windows VM", "error", err)
		} else {
			// Re-establish host routes for the Windows pod subnet
			if err := SetupRoutes(); err != nil {
				slog.Warn("[Start] Could not set up routes for Windows worker", "error", err)
			}
		}
	} else {
		slog.Info("[Start] No Windows worker VM found (linux-only mode)")
	}

	// Wait for API server to be reachable
	if err := o.waitForAPIServer(60 * time.Second); err != nil {
		slog.Warn("[Start] API server not reachable yet", "error", err)
	}

	slog.Info("[Start] K2s cluster started")
	return nil
}

func (o *LinuxOrchestrator) Stop(cfg StopConfig) error {
	slog.Info("[Stop] Stopping K2s cluster on Linux host")

	// Gracefully shutdown Windows VM
	vmManager := NewVMManager()
	if exists, _ := vmManager.VMExists(winVMName); exists {
		if err := vmManager.StopVM(winVMName); err != nil {
			slog.Warn("[Stop] Could not stop Windows VM", "error", err)
		}
	} else {
		slog.Info("[Stop] No Windows worker VM found (linux-only mode)")
	}

	// Stop kubelet
	if err := runCommand("systemctl", "stop", "kubelet"); err != nil {
		return fmt.Errorf("failed to stop kubelet: %w", err)
	}

	slog.Info("[Stop] K2s cluster stopped")
	return nil
}

// ---------- prerequisite checks ----------

func (o *LinuxOrchestrator) checkPrerequisites(cfg InstallConfig) error {
	slog.Info("[Install] Checking prerequisites")

	// Check required binaries
	requiredBins := []string{"kubeadm", "kubelet", "kubectl", "containerd"}
	if !cfg.LinuxOnly {
		requiredBins = append(requiredBins, "virsh", "qemu-img")
	}
	for _, bin := range requiredBins {
		if _, err := exec.LookPath(bin); err != nil {
			return fmt.Errorf("required binary '%s' not found in PATH: %w", bin, err)
		}
	}

	// Check kernel modules
	modules := []string{"br_netfilter", "overlay"}
	for _, mod := range modules {
		if err := runCommand("modprobe", mod); err != nil {
			return fmt.Errorf("required kernel module '%s' could not be loaded: %w", mod, err)
		}
	}

	// Ensure sysctl settings for bridged traffic
	sysctls := map[string]string{
		"net.bridge.bridge-nf-call-iptables":  "1",
		"net.bridge.bridge-nf-call-ip6tables": "1",
		"net.ipv4.ip_forward":                 "1",
	}
	for key, val := range sysctls {
		if err := runCommand("sysctl", "-w", key+"="+val); err != nil {
			slog.Warn("[Install] Could not set sysctl", "key", key, "error", err)
		}
	}

	// Check containerd is installed and can start
	if err := runCommand("systemctl", "is-enabled", "containerd"); err != nil {
		slog.Warn("[Install] containerd service not enabled, attempting to enable", "error", err)
		if err := runCommand("systemctl", "enable", "containerd"); err != nil {
			return fmt.Errorf("containerd service could not be enabled: %w", err)
		}
	}

	slog.Info("[Install] Prerequisites check passed")
	return nil
}

// ---------- control plane installation ----------

func (o *LinuxOrchestrator) installControlPlane(cfg InstallConfig) error {
	slog.Info("[Install] Installing Kubernetes control plane via kubeadm")

	// Ensure containerd is running
	if err := runCommand("systemctl", "start", "containerd"); err != nil {
		return fmt.Errorf("failed to start containerd: %w", err)
	}

	// Generate kubeadm init config with KubeletConfiguration
	initConfig := fmt.Sprintf(`apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: %s
  serviceSubnet: %s
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failCgroupV1: false
`, podNetworkCIDR, servicesCIDR)

	configDir := "/tmp/kubeadm-init"
	configPath := filepath.Join(configDir, "kubeadm-init.yaml")

	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("failed to create kubeadm init config directory: %w", err)
	}
	if err := os.WriteFile(configPath, []byte(initConfig), 0600); err != nil {
		return fmt.Errorf("failed to write kubeadm init config: %w", err)
	}

	// Build kubeadm init arguments
	args := []string{
		"init",
		"--config=" + configPath,
	}

	if cfg.Proxy != "" {
		slog.Info("[Install] Proxy configured", "proxy", cfg.Proxy)
	}

	if err := runCommand("kubeadm", args...); err != nil {
		return fmt.Errorf("kubeadm init failed: %w", err)
	}

	// Clean up temporary config
	os.Remove(configPath)

	// Enable kubelet to start on boot
	if err := runCommand("systemctl", "enable", "kubelet"); err != nil {
		slog.Warn("[Install] Could not enable kubelet service", "error", err)
	}

	slog.Info("[Install] Control plane initialized")
	return nil
}

// ---------- kubeconfig setup ----------

func (o *LinuxOrchestrator) setupKubeconfig() error {
	slog.Info("[Install] Setting up kubeconfig")

	u, err := user.Current()
	if err != nil {
		return fmt.Errorf("failed to determine current user: %w", err)
	}

	kubeDir := filepath.Join(u.HomeDir, ".kube")
	if err := os.MkdirAll(kubeDir, 0755); err != nil {
		return fmt.Errorf("failed to create .kube directory: %w", err)
	}

	destPath := filepath.Join(kubeDir, "config")

	// Copy admin.conf to user's kubeconfig
	input, err := os.ReadFile(kubeconfigSrc)
	if err != nil {
		return fmt.Errorf("failed to read kubeconfig from %s: %w", kubeconfigSrc, err)
	}
	if err := os.WriteFile(destPath, input, 0600); err != nil {
		return fmt.Errorf("failed to write kubeconfig to %s: %w", destPath, err)
	}

	slog.Info("[Install] Kubeconfig written", "path", destPath)
	return nil
}

// ---------- flannel deployment ----------

func (o *LinuxOrchestrator) deployFlannel(cfg InstallConfig) error {
	slog.Info("[Install] Deploying flannel CNI")

	templatePath := filepath.Join(cfg.InstallDir, flannelTemplateRelPath)

	templateBytes, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Errorf("failed to read flannel template from %s: %w", templatePath, err)
	}

	// Replace template placeholders
	manifest := string(templateBytes)
	manifest = strings.ReplaceAll(manifest, "NETWORK.NAME", flannelNetworkName)
	manifest = strings.ReplaceAll(manifest, "NETWORK.ADDRESS", podNetworkCIDR)
	manifest = strings.ReplaceAll(manifest, "NETWORK.TYPE", flannelBackendType)

	// Write rendered manifest to a temp file and apply
	tmpFile, err := os.CreateTemp("", "k2s-flannel-*.yml")
	if err != nil {
		return fmt.Errorf("failed to create temp file for flannel manifest: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(manifest); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to write flannel manifest: %w", err)
	}
	tmpFile.Close()

	if err := runCommand("kubectl", "apply", "-f", tmpFile.Name()); err != nil {
		return fmt.Errorf("failed to apply flannel manifest: %w", err)
	}

	slog.Info("[Install] Flannel deployed")
	return nil
}

// ---------- readiness checks ----------

func (o *LinuxOrchestrator) waitForNodeReady(timeout time.Duration) error {
	slog.Info("[Install] Waiting for control plane node to be Ready", "timeout", timeout)

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		output, err := runCommandOutput("kubectl", "get", "nodes", "-o", "jsonpath={.items[0].status.conditions[?(@.type=='Ready')].status}")
		if err == nil && strings.TrimSpace(output) == "True" {
			slog.Info("[Install] Control plane node is Ready")
			return nil
		}
		time.Sleep(5 * time.Second)
	}
	return fmt.Errorf("control plane node not ready after %s", timeout)
}

func (o *LinuxOrchestrator) waitForAPIServer(timeout time.Duration) error {
	slog.Info("[Start] Waiting for API server", "timeout", timeout)

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if err := runCommand("kubectl", "cluster-info"); err == nil {
			return nil
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("API server not reachable after %s", timeout)
}

// ---------- Windows VM provisioning ----------

func (o *LinuxOrchestrator) provisionWindowsVM(cfg InstallConfig) error {
	slog.Info("[Install] Provisioning Windows worker VM via libvirt/KVM")

	vmDataDir := filepath.Join(cfg.ConfigDir, "vm")
	diskSizeGB := parseDiskSizeGB(cfg.MasterDiskSize, 50)

	// Step 1: Create the K2s libvirt network
	if err := CreateK2sNetwork(); err != nil {
		return fmt.Errorf("failed to create K2s network: %w", err)
	}

	// Step 2: Prepare the Windows worker disk image (QCOW2)
	diskPath, err := PrepareWindowsImage(cfg.InstallDir, vmDataDir, diskSizeGB)
	if err != nil {
		return fmt.Errorf("failed to prepare Windows worker image: %w", err)
	}

	// Step 3: Create and define the VM via libvirt
	vmManager := NewVMManager()
	cpuCount := parseCPUCount(cfg.MasterVMProcessorCount, 4)
	memoryMB := parseMemoryMB(cfg.MasterVMMemory, 4096)

	vmConfig := VMConfig{
		Name:          winVMName,
		ImagePath:     diskPath,
		CPUCount:      cpuCount,
		MemoryMB:      memoryMB,
		DiskSizeGB:    diskSizeGB,
		NetworkBridge: k2sNetworkName,
	}

	if err := vmManager.CreateVM(vmConfig); err != nil {
		return fmt.Errorf("failed to create Windows VM: %w", err)
	}

	// Step 4: Start the VM
	if err := vmManager.StartVM(winVMName); err != nil {
		return fmt.Errorf("failed to start Windows VM: %w", err)
	}

	// Step 5: Wait for the VM to become reachable via SSH
	slog.Info("[Install] Waiting for Windows VM to become reachable", "ip", winVMIP)
	if err := waitForSSH(winVMIP, 22, 300*time.Second); err != nil {
		return fmt.Errorf("Windows VM not reachable via SSH within timeout: %w", err)
	}

	// Step 6: Transfer K2s worker artifacts via SSH/SCP
	slog.Info("[Install] Transferring K2s worker artifacts to Windows VM")
	if err := transferWorkerArtifacts(cfg.InstallDir, winVMIP); err != nil {
		return fmt.Errorf("failed to transfer worker artifacts: %w", err)
	}

	// Step 7: Install Windows services (containerd, kubelet, kube-proxy, flannel) via SSH
	slog.Info("[Install] Installing K2s services on Windows VM")
	if err := installWindowsServices(winVMIP); err != nil {
		return fmt.Errorf("failed to install Windows services: %w", err)
	}

	// Step 8: Generate kubeadm join token and join the Windows node
	slog.Info("[Install] Joining Windows node to cluster")
	if err := joinWindowsNode(winVMIP); err != nil {
		return fmt.Errorf("failed to join Windows node to cluster: %w", err)
	}

	// Step 9: Set up host routes for the Windows pod subnet
	if err := SetupRoutes(); err != nil {
		slog.Warn("[Install] Could not set up routes for Windows worker", "error", err)
	}

	// Step 10: Wait for Windows node to be Ready
	slog.Info("[Install] Waiting for Windows node to be Ready")
	if err := waitForWindowsNodeReady(180 * time.Second); err != nil {
		slog.Warn("[Install] Windows node not ready yet (may take a moment)", "error", err)
	}

	slog.Info("[Install] Windows worker VM provisioned successfully")
	return nil
}

// ---------- Windows VM helper functions ----------

// waitForSSH polls the given host:port until an SSH connection can be established.
func waitForSSH(host string, port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	addr := fmt.Sprintf("%s:%d", host, port)

	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err == nil {
			conn.Close()
			slog.Info("[Install] SSH port reachable", "host", host)
			return nil
		}
		time.Sleep(5 * time.Second)
	}
	return fmt.Errorf("SSH not reachable at %s after %s", addr, timeout)
}

// transferWorkerArtifacts copies K2s Windows worker binaries to the VM via SCP/SSH.
func transferWorkerArtifacts(installDir, vmIP string) error {
	// The artifacts to transfer are under installDir/bin/kube/ and installDir/bin/
	// This includes: kubelet.exe, kubeadm.exe, kubectl.exe, kube-proxy.exe,
	//                flannel.exe, containerd.exe, nssm.exe, nerdctl.exe, helm.exe
	//
	// For now, use a tar+SSH pipeline to bulk-transfer the bin/ directory.
	// The Windows VM must have OpenSSH pre-installed in the base image.

	binDir := filepath.Join(installDir, "bin")
	remoteDir := `C:\k2s\bin`

	// Create remote directory
	if err := sshExecOnVM(vmIP, fmt.Sprintf(`mkdir -Force "%s"`, remoteDir)); err != nil {
		slog.Warn("[Install] Could not create remote bin directory (may already exist)", "error", err)
	}

	// Transfer key binaries individually
	binaries := []string{
		"kube/kubelet.exe", "kube/kubeadm.exe", "kube/kubectl.exe", "kube/kube-proxy.exe",
		"kube/flannel.exe", "kube/nssm.exe", "containerd/containerd.exe",
		"nerdctl.exe", "kube/helm.exe",
	}

	for _, bin := range binaries {
		localPath := filepath.Join(binDir, bin)
		if _, err := os.Stat(localPath); err != nil {
			slog.Warn("[Install] Binary not found, skipping", "path", localPath)
			continue
		}
		remotePath := fmt.Sprintf(`C:\k2s\bin\%s`, filepath.Base(bin))
		if err := scpToVM(vmIP, localPath, remotePath); err != nil {
			return fmt.Errorf("failed to transfer '%s': %w", bin, err)
		}
	}

	// Transfer configuration files
	cfgDir := filepath.Join(installDir, "cfg")
	if err := sshExecOnVM(vmIP, `mkdir -Force "C:\k2s\cfg"`); err != nil {
		slog.Warn("[Install] Could not create remote cfg directory", "error", err)
	}

	// Create kubelet drop-in directory for configuration overrides
	if err := sshExecOnVM(vmIP, `mkdir -Force "C:\etc\kubernetes\kubelet.conf.d"`); err != nil {
		slog.Warn("[Install] Could not create kubelet drop-in directory", "error", err)
	}

	cfgFiles := []string{"kubeadm/joinnode.template.yaml", "containerd/config.toml", "cni/net-conf.json"}
	for _, cf := range cfgFiles {
		localPath := filepath.Join(cfgDir, cf)
		if _, err := os.Stat(localPath); err != nil {
			continue
		}
		remotePath := fmt.Sprintf(`C:\k2s\cfg\%s`, filepath.Base(cf))
		if err := scpToVM(vmIP, localPath, remotePath); err != nil {
			slog.Warn("[Install] Could not transfer config file", "file", cf, "error", err)
		}
	}

	return nil
}

// installWindowsServices installs NSSM-managed services on the Windows VM.
func installWindowsServices(vmIP string) error {
	services := []struct {
		name    string
		binary  string
		args    string
	}{
		{"containerd", `C:\k2s\bin\containerd.exe`, `--config "C:\k2s\cfg\config.toml"`},
		{"flanneld", `C:\k2s\bin\flannel.exe`, `--kubeconfig-file "C:\k2s\config" --iface=Ethernet --ip-masq --kube-subnet-mgr`},
		{"kubelet", `C:\k2s\bin\kubelet.exe`, `--config "C:\k2s\cfg\kubelet-config.yaml" --config-dir "C:\etc\kubernetes\kubelet.conf.d" --kubeconfig "C:\k2s\config" --hostname-override=%COMPUTERNAME%`},
		{"kubeproxy", `C:\k2s\bin\kube-proxy.exe`, `--kubeconfig "C:\k2s\config" --hostname-override=%COMPUTERNAME%`},
	}

	nssmPath := `C:\k2s\bin\nssm.exe`

	for _, svc := range services {
		cmd := fmt.Sprintf(`%s install %s "%s" %s`, nssmPath, svc.name, svc.binary, svc.args)
		if err := sshExecOnVM(vmIP, cmd); err != nil {
			return fmt.Errorf("failed to install service '%s': %w", svc.name, err)
		}
	}

	// Start services in order
	startOrder := []string{"containerd", "flanneld", "kubelet", "kubeproxy"}
	for _, svc := range startOrder {
		cmd := fmt.Sprintf(`%s start %s`, nssmPath, svc)
		if err := sshExecOnVM(vmIP, cmd); err != nil {
			slog.Warn("[Install] Could not start service (may be started by kubeadm join)", "service", svc, "error", err)
		}
	}

	return nil
}

// joinWindowsNode generates a kubeadm join token and executes kubeadm join on the Windows VM.
func joinWindowsNode(vmIP string) error {
	// Generate a join command on the control plane
	joinOutput, err := runCommandOutput("kubeadm", "token", "create", "--print-join-command")
	if err != nil {
		return fmt.Errorf("failed to create join token: %w", err)
	}

	joinCmd := strings.TrimSpace(joinOutput)
	slog.Info("[Install] Join command generated", "command", joinCmd)

	// Execute kubeadm join on the Windows VM
	// Windows kubeadm expects: kubeadm join <api> --token <token> --discovery-token-ca-cert-hash <hash>
	// --ignore-preflight-errors=IsPrivilegedUser,SystemVerification
	winJoinCmd := fmt.Sprintf(`C:\k2s\bin\kubeadm.exe %s --ignore-preflight-errors=IsPrivilegedUser,SystemVerification --cri-socket npipe:////./pipe/containerd-containerd`,
		strings.TrimPrefix(joinCmd, "kubeadm "))

	if err := sshExecOnVM(vmIP, winJoinCmd); err != nil {
		return fmt.Errorf("kubeadm join failed on Windows VM: %w", err)
	}

	return nil
}

// waitForWindowsNodeReady waits until the Windows worker node reports Ready.
func waitForWindowsNodeReady(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		output, err := runCommandOutput("kubectl", "get", "nodes", "-o", "jsonpath={range .items[*]}{.metadata.name}={.status.conditions[?(@.type=='Ready')].status}{','}{end}")
		if err == nil {
			for _, entry := range strings.Split(output, ",") {
				parts := strings.SplitN(entry, "=", 2)
				if len(parts) == 2 && parts[1] == "True" && parts[0] != "" {
					// Check if this is the Windows node (not the control plane)
					nodeOS, _ := runCommandOutput("kubectl", "get", "node", parts[0], "-o", "jsonpath={.status.nodeInfo.operatingSystem}")
					if strings.TrimSpace(nodeOS) == "windows" {
						slog.Info("[Install] Windows node is Ready", "name", parts[0])
						return nil
					}
				}
			}
		}
		time.Sleep(5 * time.Second)
	}
	return fmt.Errorf("Windows node not ready after %s", timeout)
}

// sshExecOnVM executes a command on the Windows VM via SSH.
// Requires OpenSSH to be installed on the Windows worker image.
func sshExecOnVM(vmIP, command string) error {
	slog.Debug("[SSH] Executing on Windows VM", "ip", vmIP, "command", command)
	return runCommand("ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		fmt.Sprintf("remote@%s", vmIP),
		command,
	)
}

// scpToVM copies a local file to the Windows VM via SCP.
func scpToVM(vmIP, localPath, remotePath string) error {
	slog.Debug("[SCP] Copying to Windows VM", "local", localPath, "remote", remotePath, "ip", vmIP)
	return runCommand("scp",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		localPath,
		fmt.Sprintf("remote@%s:%s", vmIP, remotePath),
	)
}

// ---------- parameter parsing helpers ----------

func parseCPUCount(value string, defaultVal int) int {
	if value == "" {
		return defaultVal
	}
	n := defaultVal
	fmt.Sscanf(value, "%d", &n)
	if n <= 0 {
		return defaultVal
	}
	return n
}

func parseMemoryMB(value string, defaultVal int) int {
	if value == "" {
		return defaultVal
	}
	val := strings.ToUpper(strings.TrimSpace(value))
	n := defaultVal
	if strings.HasSuffix(val, "GB") {
		fmt.Sscanf(strings.TrimSuffix(val, "GB"), "%d", &n)
		n *= 1024
	} else if strings.HasSuffix(val, "MB") {
		fmt.Sscanf(strings.TrimSuffix(val, "MB"), "%d", &n)
	} else {
		fmt.Sscanf(val, "%d", &n)
	}
	if n <= 0 {
		return defaultVal
	}
	return n
}

func parseDiskSizeGB(value string, defaultVal int) int {
	if value == "" {
		return defaultVal
	}
	val := strings.ToUpper(strings.TrimSpace(value))
	n := defaultVal
	if strings.HasSuffix(val, "GB") {
		fmt.Sscanf(strings.TrimSuffix(val, "GB"), "%d", &n)
	} else {
		fmt.Sscanf(val, "%d", &n)
	}
	if n <= 0 {
		return defaultVal
	}
	return n
}

// ---------- command helpers ----------

// runCommand executes a command and returns any error.
func runCommand(name string, args ...string) error {
	slog.Debug("Executing command", "cmd", name, "args", args)
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		slog.Error("Command failed", "cmd", name, "output", string(output), "error", err)
		return fmt.Errorf("%s failed: %w\nOutput: %s", name, err, string(output))
	}
	slog.Debug("Command succeeded", "cmd", name, "output", string(output))
	return nil
}

// runCommandOutput executes a command and returns its stdout as a string.
func runCommandOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s failed: %w", name, err)
	}
	return string(output), nil
}
