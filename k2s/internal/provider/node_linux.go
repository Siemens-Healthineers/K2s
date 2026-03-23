// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
)

type linuxNodeProvider struct {
	installDir string
}

func newLinuxNodeProvider(cfg ProviderConfig) *linuxNodeProvider {
	return &linuxNodeProvider{installDir: cfg.InstallDir}
}

func (p *linuxNodeProvider) Add(cfg NodeAddConfig) error {
	slog.Info("[Node] Adding node", "type", cfg.NodeType, "ip", cfg.IpAddress)

	// Generate join token on control plane
	output, err := exec.Command("kubeadm", "token", "create", "--print-join-command").Output()
	if err != nil {
		return fmt.Errorf("failed to create join token: %w", err)
	}
	joinCmd := strings.TrimSpace(string(output))

	// Execute join on the target node via SSH
	remoteCmd := joinCmd
	if cfg.NodeType == "windows" {
		// Windows kubeadm needs extra flags
		remoteCmd = fmt.Sprintf(`C:\k2s\bin\kubeadm.exe %s --ignore-preflight-errors=IsPrivilegedUser,SystemVerification --cri-socket npipe:////./pipe/containerd-containerd`,
			strings.TrimPrefix(joinCmd, "kubeadm "))
	}

	_, err = sshCmd(remoteCmd)
	if err != nil {
		return fmt.Errorf("kubeadm join failed on remote node: %w", err)
	}

	slog.Info("[Node] Node added successfully")
	return nil
}

func (p *linuxNodeProvider) Remove(cfg NodeRemoveConfig) error {
	slog.Info("[Node] Removing node", "name", cfg.NodeName)

	// Drain the node
	if err := exec.Command("kubectl", "drain", cfg.NodeName, "--ignore-daemonsets", "--delete-emptydir-data", "--force").Run(); err != nil {
		slog.Warn("[Node] Drain failed (continuing with removal)", "error", err)
	}

	// Delete the node from the cluster
	if err := exec.Command("kubectl", "delete", "node", cfg.NodeName).Run(); err != nil {
		return fmt.Errorf("failed to delete node '%s': %w", cfg.NodeName, err)
	}

	slog.Info("[Node] Node removed", "name", cfg.NodeName)
	return nil
}
