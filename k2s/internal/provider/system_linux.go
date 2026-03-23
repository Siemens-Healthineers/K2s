// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
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
	return exec.Command("kubeadm", "certs", "renew", "all").Run()
}
