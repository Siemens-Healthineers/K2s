// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
<<<<<<< HEAD
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
=======
	"os/exec"
>>>>>>> main
)

// LinuxOrchestrator implements Orchestrator using native Linux tools:
// kubeadm, systemctl, and libvirt for managing a Windows worker VM.
type LinuxOrchestrator struct{}

// NewOrchestrator returns the platform-specific orchestrator.
// On Linux, it returns a native kubeadm/systemd/libvirt orchestrator.
func NewOrchestrator(_ interface{}) Orchestrator {
	return &LinuxOrchestrator{}
}

<<<<<<< HEAD
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
=======
func (o *LinuxOrchestrator) Install(config InstallConfig) error {
	slog.Info("Installing K2s on Linux host")

	// Phase 1: Install control plane natively via kubeadm
	if err := o.installControlPlane(config); err != nil {
		return fmt.Errorf("failed to install control plane: %w", err)
	}

	// Phase 2: Deploy flannel CNI with Windows node support
	if err := o.deployFlannel(); err != nil {
		return fmt.Errorf("failed to deploy flannel: %w", err)
	}

	if !config.LinuxOnly {
		// Phase 3: Create and provision Windows worker VM
		if err := o.provisionWindowsVM(config); err != nil {
>>>>>>> main
			return fmt.Errorf("failed to provision Windows VM: %w", err)
		}
	}

<<<<<<< HEAD
	slog.Info("[Install] K2s installation complete")
	return nil
}

func (o *LinuxOrchestrator) Uninstall(cfg UninstallConfig) error {
	slog.Info("[Uninstall] Uninstalling K2s from Linux host")

	// Stop and remove Windows VM if it exists
	_ = runCommand("virsh", "destroy", winVMName)
	_ = runCommand("virsh", "undefine", winVMName, "--remove-all-storage")

	// Reset kubeadm
	if !cfg.SkipPurge {
		if err := runCommand("kubeadm", "reset", "-f"); err != nil {
			slog.Warn("[Uninstall] kubeadm reset failed (may already be clean)", "error", err)
		}
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

func (o *LinuxOrchestrator) Start(cfg StartConfig) error {
	slog.Info("[Start] Starting K2s cluster on Linux host")

	// Start kubelet — control plane static pods come up automatically
=======
	slog.Info("K2s installation complete")
	return nil
}

func (o *LinuxOrchestrator) Uninstall(config UninstallConfig) error {
	slog.Info("Uninstalling K2s from Linux host")

	// Stop Windows VM if running
	_ = runCommand("virsh", "destroy", "k2s-win-worker")
	_ = runCommand("virsh", "undefine", "k2s-win-worker", "--remove-all-storage")

	// Reset kubeadm
	if !config.SkipPurge {
		_ = runCommand("kubeadm", "reset", "-f")
	}

	// Clean up network
	_ = runCommand("ip", "link", "delete", "cni0")
	_ = runCommand("ip", "link", "delete", "flannel.1")

	slog.Info("K2s uninstallation complete")
	return nil
}

func (o *LinuxOrchestrator) Start(config StartConfig) error {
	slog.Info("Starting K2s cluster on Linux host")

	// Start kubelet (control plane comes up automatically)
>>>>>>> main
	if err := runCommand("systemctl", "start", "kubelet"); err != nil {
		return fmt.Errorf("failed to start kubelet: %w", err)
	}

<<<<<<< HEAD
	// Start Windows VM if it exists
	if err := runCommand("virsh", "start", winVMName); err != nil {
		slog.Info("[Start] Windows VM not started (may not exist in linux-only mode)", "error", err)
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
	if err := runCommand("virsh", "shutdown", winVMName); err != nil {
		slog.Info("[Stop] Windows VM not stopped (may not exist in linux-only mode)", "error", err)
	}
=======
	// Start Windows VM
	if err := runCommand("virsh", "start", "k2s-win-worker"); err != nil {
		slog.Warn("Could not start Windows VM (may not exist in linux-only mode)", "error", err)
	}

	slog.Info("K2s cluster started")
	return nil
}

func (o *LinuxOrchestrator) Stop(config StopConfig) error {
	slog.Info("Stopping K2s cluster on Linux host")

	// Gracefully shutdown Windows VM
	_ = runCommand("virsh", "shutdown", "k2s-win-worker")
>>>>>>> main

	// Stop kubelet
	if err := runCommand("systemctl", "stop", "kubelet"); err != nil {
		return fmt.Errorf("failed to stop kubelet: %w", err)
	}

<<<<<<< HEAD
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

	// Build kubeadm init arguments
	args := []string{
		"init",
		"--pod-network-cidr=" + podNetworkCIDR,
		"--service-cidr=" + servicesCIDR,
	}

	if cfg.Proxy != "" {
		slog.Info("[Install] Proxy configured", "proxy", cfg.Proxy)
=======
	slog.Info("K2s cluster stopped")
	return nil
}

func (o *LinuxOrchestrator) installControlPlane(config InstallConfig) error {
	slog.Info("Installing Kubernetes control plane via kubeadm")

	// Ensure containerd is running
	if err := runCommand("systemctl", "enable", "--now", "containerd"); err != nil {
		return fmt.Errorf("failed to start containerd: %w", err)
	}

	// Initialize control plane
	args := []string{"init",
		"--pod-network-cidr=172.20.0.0/16",
		"--service-cidr=172.21.0.0/16",
		"--ignore-preflight-errors=SystemVerification",
>>>>>>> main
	}

	if err := runCommand("kubeadm", args...); err != nil {
		return fmt.Errorf("kubeadm init failed: %w", err)
	}

<<<<<<< HEAD
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

// ---------- Windows VM provisioning (Phase 3 — future) ----------

func (o *LinuxOrchestrator) provisionWindowsVM(cfg InstallConfig) error {
	slog.Info("[Install] Provisioning Windows worker VM via libvirt/KVM")

	// TODO: Implement in Phase 3:
	// 1. Convert VHDX → QCOW2 via qemu-img convert (or use pre-built QCOW2)
	// 2. Define VM via virsh with virtio networking
	// 3. Boot VM, wait for SSH/WinRM
	// 4. Transfer K2s Windows worker artifacts
	// 5. Install NSSM services (containerd, kubelet, kube-proxy, flannel)
	// 6. Generate kubeadm join token and join the cluster
	// 7. Wait for Windows node Ready

	slog.Warn("[Install] Windows VM provisioning not yet implemented (Phase 3)")
	return nil
}

// ---------- command helpers ----------

=======
	slog.Info("Control plane initialized")
	return nil
}

func (o *LinuxOrchestrator) deployFlannel() error {
	slog.Info("Deploying flannel with Windows support")

	// Apply flannel manifest with VXLAN backend + Windows DaemonSet
	// TODO: Use offline manifests from package or apply from bundled YAML
	if err := runCommand("kubectl", "apply", "-f",
		"https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"); err != nil {
		return fmt.Errorf("failed to deploy flannel: %w", err)
	}

	return nil
}

func (o *LinuxOrchestrator) provisionWindowsVM(config InstallConfig) error {
	slog.Info("Provisioning Windows worker VM via libvirt/KVM")

	// TODO: Implement Windows VM provisioning:
	// 1. Create VM from Windows base qcow2 image via virsh/libvirt
	// 2. Wait for VM to boot
	// 3. SSH/WinRM into VM
	// 4. Install containerd, kubelet, kube-proxy, flannel, NSSM
	// 5. Run kubeadm join
	// 6. Wait for node Ready

	slog.Warn("Windows VM provisioning not yet implemented")
	return nil
}

>>>>>>> main
// runCommand executes a command and returns any error.
func runCommand(name string, args ...string) error {
	slog.Debug("Executing command", "cmd", name, "args", args)
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		slog.Error("Command failed", "cmd", name, "output", string(output), "error", err)
<<<<<<< HEAD
		return fmt.Errorf("%s failed: %w\nOutput: %s", name, err, string(output))
=======
		return fmt.Errorf("%s failed: %w", name, err)
>>>>>>> main
	}
	slog.Debug("Command succeeded", "cmd", name, "output", string(output))
	return nil
}
<<<<<<< HEAD

// runCommandOutput executes a command and returns its stdout as a string.
func runCommandOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s failed: %w", name, err)
	}
	return string(output), nil
}
=======
>>>>>>> main
