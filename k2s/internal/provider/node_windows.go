// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	k2sos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type windowsNodeProvider struct {
	installDir string
	stdWriter  k2sos.StdWriter
}

func newWindowsNodeProvider(cfg ProviderConfig) *windowsNodeProvider {
	return &windowsNodeProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

// getSSHKeyPath returns the path to the SSH private key for the control plane.
// The key is stored in ~/.ssh/k2s/id_rsa
func (p *windowsNodeProvider) getSSHKeyPath() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to determine user home dir: %w", err)
	}
	return filepath.Join(homeDir, ".ssh", definitions.SSHSubDirName, definitions.SSHPrivateKeyName), nil
}

// detectRemoteOS detects whether the remote machine is running Windows or Linux
// by attempting to run a simple command via SSH. Returns "windows" or "linux".
func (p *windowsNodeProvider) detectRemoteOS(userName, ipAddress string) (string, error) {
	slog.Debug("[Node] Detecting remote OS", "ip", ipAddress, "user", userName)

	keyPath, err := p.getSSHKeyPath()
	if err != nil {
		return "", fmt.Errorf("failed to get SSH key path: %w", err)
	}

	// Check if the SSH key exists
	if _, err := os.Stat(keyPath); os.IsNotExist(err) {
		return "", fmt.Errorf("SSH private key not found at '%s'. Ensure the K2s cluster is properly set up", keyPath)
	}

	// Use ssh.exe with StrictHostKeyChecking=no to avoid host key verification issues
	// This matches the behavior in Invoke-SSHWithKey from vm.module.psm1
	userAtHost := fmt.Sprintf("%s@%s", userName, ipAddress)

	// Try Windows detection: run 'powershell.exe -Command echo windows'
	windowsCmd := exec.Command("ssh.exe",
		"-n",
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=no",
		"-o", "ConnectTimeout=10",
		"-i", keyPath,
		userAtHost,
		"powershell.exe -Command \"echo windows\"")

	output, err := windowsCmd.CombinedOutput()
	outputStr := strings.TrimSpace(string(output))

	slog.Debug("[Node] Windows detection attempt", "output", outputStr, "error", err)

	if err == nil && strings.Contains(strings.ToLower(outputStr), "windows") {
		slog.Info("[Node] Detected remote OS: Windows", "ip", ipAddress)
		return "windows", nil
	}

	// Try Linux detection: run 'which ls'
	linuxCmd := exec.Command("ssh.exe",
		"-n",
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=no",
		"-o", "ConnectTimeout=10",
		"-i", keyPath,
		userAtHost,
		"which ls")

	output, err = linuxCmd.CombinedOutput()
	outputStr = strings.TrimSpace(string(output))

	slog.Debug("[Node] Linux detection attempt", "output", outputStr, "error", err)

	if err == nil && strings.Contains(outputStr, "/") {
		slog.Info("[Node] Detected remote OS: Linux", "ip", ipAddress)
		return "linux", nil
	}

	return "", fmt.Errorf("unable to detect remote OS for %s@%s: neither Windows nor Linux commands succeeded", userName, ipAddress)
}

func (p *windowsNodeProvider) Add(cfg NodeAddConfig) error {
	// Detect remote OS to determine which script to invoke
	remoteOS, err := p.detectRemoteOS(cfg.UserName, cfg.IpAddress)
	if err != nil {
		return fmt.Errorf("failed to detect remote OS: %w", err)
	}

	var psCmd string
	if remoteOS == "windows" {
		psCmd = utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "worker", "windows", "windows-host", "Add.ps1"))
	} else {
		psCmd = utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "worker", "linux", "bare-metal", "Add.ps1"))
	}

	slog.Info("[Node] Adding node", "ip", cfg.IpAddress, "user", cfg.UserName, "os", remoteOS, "script", psCmd)

	var params string
	if cfg.UserName != "" {
		params += " -UserName " + cfg.UserName
	}
	if cfg.IpAddress != "" {
		params += " -IpAddress " + cfg.IpAddress
	}
	if cfg.NodeName != "" {
		params += " -NodeName " + cfg.NodeName
	}
	if cfg.NodePackagePath != "" {
		params += " -NodePackagePath '" + cfg.NodePackagePath + "'"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsNodeProvider) Remove(cfg NodeRemoveConfig) error {
	psCmd := utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "worker", "linux", "bare-metal", "Remove.ps1"))

	var params string
	if cfg.NodeName != "" {
		params += " -NodeName " + cfg.NodeName
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}
