// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	k2sos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type windowsSystemProvider struct {
	installDir string
	stdWriter  k2sos.StdWriter
}

func newWindowsSystemProvider(cfg ProviderConfig) *windowsSystemProvider {
	return &windowsSystemProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsSystemProvider) scriptPath(script string) string {
	return utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "k2s", "system", script))
}

func (p *windowsSystemProvider) execPS(psCmd string, params ...string) error {
	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](psCmd, "CmdResult", p.stdWriter, params...)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsSystemProvider) Dump(cfg SystemDumpConfig) error {
	psCmd := p.scriptPath("dump/Dump-Status.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Upgrade(cfg SystemUpgradeConfig) error {
	psCmd := p.scriptPath("upgrade/Start-ClusterUpdate.ps1")
	var params string
	if cfg.PackagePath != "" {
		params += fmt.Sprintf(" -ZipFilePath '%s'", cfg.PackagePath)
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
	if cfg.ForceOnline {
		params += " -ForceOnlineInstallation"
	}
	if cfg.DeletePackage {
		params += " -DeleteFiles"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.AdditionalHooksDir != "" {
		params += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Package(cfg SystemPackageConfig) error {
	psCmd := p.scriptPath("package/New-K2sPackage.ps1")
	var params []string
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Reset(cfg SystemResetConfig) error {
	psCmd := p.scriptPath("reset/Reset.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) ResetNetwork(cfg SystemResetNetworkConfig) error {
	psCmd := p.scriptPath("reset/Reset-Network.ps1")
	var params []string
	if cfg.AdditionalHooksDir != "" {
		params = append(params, fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Compact(cfg SystemCompactConfig) error {
	psCmd := p.scriptPath("compact/Compact-Vhdx.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Backup(cfg SystemBackupConfig) error {
	psCmd := p.scriptPath("backup/Backup.ps1")
	var params string
	if cfg.BackupDir != "" {
		params += fmt.Sprintf(" -BackupDir '%s'", cfg.BackupDir)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Restore(cfg SystemRestoreConfig) error {
	psCmd := p.scriptPath("restore/Restore.ps1")
	var params string
	if cfg.BackupDir != "" {
		params += fmt.Sprintf(" -BackupDir '%s'", cfg.BackupDir)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) CertificateRenew(cfg SystemCertRenewConfig) error {
	psCmd := p.scriptPath("certificate/Renew-Certificate.ps1")
	var params []string
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}
