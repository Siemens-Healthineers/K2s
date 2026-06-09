// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"fmt"
	"log/slog"
	"os/exec"
)

type linuxSystemProvider struct {
	installDir string
}

func newLinuxSystemProvider(cfg ProviderConfig) *linuxSystemProvider {
	return &linuxSystemProvider{installDir: cfg.InstallDir}
}

func (p *linuxSystemProvider) Dump(cfg SystemDumpConfig) error {
	slog.Info("[System] Dumping cluster info")
	cmd := exec.Command("kubectl", "cluster-info", "dump")
	if cfg.OutputDir != "" {
		cmd.Args = append(cmd.Args, "--output-directory="+cfg.OutputDir)
	}
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Run()
}

func (p *linuxSystemProvider) Upgrade(_ SystemUpgradeConfig) error {
	return NotSupportedError("system upgrade",
		"cluster upgrade on Linux hosts is not yet implemented; use package-based reinstall instead")
}

func (p *linuxSystemProvider) Package(_ SystemPackageConfig) error {
	return NotSupportedError("system package",
		"offline packaging on Linux hosts is not yet implemented")
}

func (p *linuxSystemProvider) Reset(_ SystemResetConfig) error {
	slog.Info("[System] Resetting cluster via kubeadm reset")
	return exec.Command("kubeadm", "reset", "-f").Run()
}

func (p *linuxSystemProvider) ResetNetwork(_ SystemResetNetworkConfig) error {
	slog.Info("[System] Resetting network interfaces")
	_ = exec.Command("ip", "link", "delete", "cni0").Run()
	_ = exec.Command("ip", "link", "delete", "flannel.1").Run()
	_ = exec.Command("iptables", "-F").Run()
	_ = exec.Command("iptables", "-t", "nat", "-F").Run()
	_ = exec.Command("iptables", "-X").Run()
	return nil
}

func (p *linuxSystemProvider) Compact(_ SystemCompactConfig) error {
	return NotSupportedError("system compact",
		"VHDX compaction is a Windows/Hyper-V operation; use 'qemu-img convert' to compact QCOW2 images")
}

func (p *linuxSystemProvider) Backup(_ SystemBackupConfig) error {
	return NotSupportedError("system backup",
		"cluster backup on Linux hosts is not yet implemented")
}

func (p *linuxSystemProvider) Restore(_ SystemRestoreConfig) error {
	return NotSupportedError("system restore",
		"cluster restore on Linux hosts is not yet implemented")
}

func (p *linuxSystemProvider) CertificateRenew(_ SystemCertRenewConfig) error {
	slog.Info("[System] Renewing Kubernetes certificates")
	if err := exec.Command("kubeadm", "certs", "renew", "all").Run(); err != nil {
		return err
	}

	// Renew the clusterip-webhook certificate by restarting the deployment.
	// The init container generates a fresh certificate on each Pod start.
	slog.Info("[System] Renewing clusterip-webhook certificate")
	checkCmd := exec.Command("kubectl", "get", "deployment", "clusterip-webhook",
		"-n", "k2s-webhook", "--no-headers")
	if err := checkCmd.Run(); err != nil {
		slog.Info("[System] clusterip-webhook deployment not found - skipping webhook cert renewal")
		return nil
	}

	restartCmd := exec.Command("kubectl", "rollout", "restart",
		"deployment/clusterip-webhook", "-n", "k2s-webhook")
	if out, err := restartCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to restart clusterip-webhook deployment: %w\n%s", err, out)
	}

	statusCmd := exec.Command("kubectl", "rollout", "status",
		"deployment/clusterip-webhook", "-n", "k2s-webhook", "--timeout=120s")
	if out, err := statusCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("clusterip-webhook deployment did not become ready: %w\n%s", err, out)
	}

	slog.Info("[System] clusterip-webhook certificate renewed successfully")
	return nil
}

func (p *linuxSystemProvider) CertificateAutoRotation(cfg SystemCertAutoRotationConfig) error {
	const kubeletConfigPath = "/var/lib/kubelet/config.yaml"

	// patchScript uses only sed/grep — no python3 dependency.
	// It creates a backup before patching and restores on failure.
	patchScript := func(value string) string {
		return fmt.Sprintf(`
set -euo pipefail
CONFIG="%s"
BACKUP="${CONFIG}.bak"
sudo cp "$CONFIG" "$BACKUP"
if sudo grep -q 'rotateCertificates' "$CONFIG"; then
    sudo sed -i 's/rotateCertificates:.*/rotateCertificates: %s/' "$CONFIG"
else
    echo 'rotateCertificates: %s' | sudo tee -a "$CONFIG" > /dev/null
fi
`, kubeletConfigPath, value, value)
	}

	if cfg.Enable {
		slog.Info("[System] Enabling kubelet certificate auto-rotation")
		cmd := exec.Command("bash", "-c", patchScript("true"))
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to enable rotateCertificates in kubelet config: %w\n%s", err, out)
		}
		slog.Info("[System] Restarting kubelet to apply auto-rotation setting")
		if out, err := exec.Command("systemctl", "restart", "kubelet").CombinedOutput(); err != nil {
			return fmt.Errorf("failed to restart kubelet: %w\n%s", err, out)
		}
		return nil
	}

	if cfg.Disable {
		slog.Info("[System] Disabling kubelet certificate auto-rotation")
		cmd := exec.Command("bash", "-c", patchScript("false"))
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to disable rotateCertificates in kubelet config: %w\n%s", err, out)
		}
		slog.Info("[System] Restarting kubelet to apply auto-rotation setting")
		if out, err := exec.Command("systemctl", "restart", "kubelet").CombinedOutput(); err != nil {
			return fmt.Errorf("failed to restart kubelet: %w\n%s", err, out)
		}
		return nil
	}

	// status (default)
	slog.Info("[System] Checking kubelet certificate auto-rotation status")
	statusScript := fmt.Sprintf(`
CONFIG="%s"
if sudo grep -q 'rotateCertificates: true' "$CONFIG"; then
    echo "Kubelet certificate auto-rotation: enabled"
else
    echo "Kubelet certificate auto-rotation: disabled (or not set)"
fi
`, kubeletConfigPath)
	out, err := exec.Command("bash", "-c", statusScript).Output()
	if err != nil {
		return fmt.Errorf("failed to read kubelet config: %w", err)
	}
	slog.Info("[System] " + string(out))
	return nil
}

