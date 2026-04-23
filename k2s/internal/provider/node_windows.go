// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
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

func (p *windowsNodeProvider) Add(cfg NodeAddConfig) error {
	// Detect remote OS first to choose the appropriate script
	scriptPath, err := p.detectRemoteOSAndGetScriptPath(cfg.UserName, cfg.IpAddress)
	if err != nil {
		return fmt.Errorf("failed to detect remote OS: %w", err)
	}

	psCmd := utils.FormatScriptFilePath(scriptPath)

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

// detectRemoteOSAndGetScriptPath detects the operating system of the remote machine
// and returns the appropriate PowerShell script path
func (p *windowsNodeProvider) detectRemoteOSAndGetScriptPath(userName, ipAddress string) (string, error) {
	// Create a PowerShell script that imports the infra module and tests for Windows
	testScript := fmt.Sprintf(`
		$infraModule = "%s"
		Import-Module $infraModule
		
		# Test for Windows first by trying a PowerShell command
		try {
			$result = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell.exe -Command "Get-Command"' -UserName %s -IpAddress %s
			if ($result.Success) {
				Write-Host "WINDOWS_DETECTED"
			} else {
				Write-Host "LINUX_DETECTED"
			}
		} catch {
			Write-Host "LINUX_DETECTED"
		}
	`, filepath.Join(p.installDir, "lib", "modules", "k2s", "k2s.infra.module", "k2s.infra.module.psm1"), userName, ipAddress)

	// Execute the test script using PowerShell
	output := &strings.Builder{}
	stdWriter := &simpleStdWriter{output: output}

	err := powershell.ExecutePs(testScript, stdWriter)
	if err != nil {
		return "", fmt.Errorf("failed to execute OS detection script: %w", err)
	}

	detectedOutput := strings.TrimSpace(output.String())

	// Check if Windows was detected
	if strings.Contains(detectedOutput, "WINDOWS_DETECTED") {
		return filepath.Join(p.installDir, "lib", "scripts", "worker", "windows", "windows-host", "Add.ps1"), nil
	} else {
		return filepath.Join(p.installDir, "lib", "scripts", "worker", "linux", "bare-metal", "Add.ps1"), nil
	}
}

// simpleStdWriter implements os.StdWriter for capturing output
type simpleStdWriter struct {
	output *strings.Builder
}

func (w *simpleStdWriter) WriteStdOut(message string) {
	w.output.WriteString(message)
}

func (w *simpleStdWriter) WriteStdErr(message string) {
	w.output.WriteString(message)
}

func (w *simpleStdWriter) Flush() {
	// No-op for this simple implementation
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
