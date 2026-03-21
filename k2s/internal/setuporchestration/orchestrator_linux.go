// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"os/exec"
)

// LinuxOrchestrator implements Orchestrator using native Linux tools:
// kubeadm, systemctl, and libvirt for managing a Windows worker VM.
type LinuxOrchestrator struct{}

// NewOrchestrator returns the platform-specific orchestrator.
// On Linux, it returns a native kubeadm/systemd/libvirt orchestrator.
func NewOrchestrator(_ interface{}) Orchestrator {
	return &LinuxOrchestrator{}
}

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
			return fmt.Errorf("failed to provision Windows VM: %w", err)
		}
	}

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
	if err := runCommand("systemctl", "start", "kubelet"); err != nil {
		return fmt.Errorf("failed to start kubelet: %w", err)
	}

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

	// Stop kubelet
	if err := runCommand("systemctl", "stop", "kubelet"); err != nil {
		return fmt.Errorf("failed to stop kubelet: %w", err)
	}

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
	}

	if err := runCommand("kubeadm", args...); err != nil {
		return fmt.Errorf("kubeadm init failed: %w", err)
	}

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

// runCommand executes a command and returns any error.
func runCommand(name string, args ...string) error {
	slog.Debug("Executing command", "cmd", name, "args", args)
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		slog.Error("Command failed", "cmd", name, "output", string(output), "error", err)
		return fmt.Errorf("%s failed: %w", name, err)
	}
	slog.Debug("Command succeeded", "cmd", name, "output", string(output))
	return nil
}
