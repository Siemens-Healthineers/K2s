// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
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
	psCmd := p.scriptPath("dump/dump.ps1")
	var params string
	if cfg.SkipOpenDump {
		params += " -OpenDumpFolder `$false"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.Nodes != "" {
		params += " -Nodes " + utils.EscapeWithSingleQuotes(cfg.Nodes)
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Upgrade(cfg SystemUpgradeConfig) error {
	if cfg.NodeName != "" && cfg.NodePackagePath != "" {
		psCmd := p.scriptPath("upgrade/Upgrade-K2sNode.ps1")
		var params string
		params += " -NodeName " + cfg.NodeName
		params += fmt.Sprintf(" -NodePackagePath '%s'", cfg.NodePackagePath)
		if cfg.ShowOutput {
			params += " -ShowLogs"
		}
		return powershell.ExecutePs(psCmd+params, p.stdWriter)
	}

	psCmd := p.scriptPath("upgrade/Start-ClusterUpgrade.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.SkipResources {
		params += " -SkipResources"
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
	if cfg.DeletePackage {
		params += " -DeleteFiles"
	}
	if cfg.ConfigFile != "" {
		params += " -Config " + cfg.ConfigFile
	}
	if cfg.Proxy != "" {
		params += " -Proxy " + cfg.Proxy
	}
	if cfg.BackupDir != "" {
		params += fmt.Sprintf(" -BackupDir '%s'", cfg.BackupDir)
	}
	if cfg.AdditionalHooksDir != "" {
		params += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
	if cfg.Force {
		params += " -Force"
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
	psCmd := p.scriptPath("reset/Reset-System.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) ResetNetwork(cfg SystemResetNetworkConfig) error {
	psCmd := p.scriptPath("reset/network/Reset-Network.ps1")
	var params []string
	if cfg.Force {
		params = append(params, " -Force")
	}
	if cfg.AdditionalHooksDir != "" {
		params = append(params, fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Compact(cfg SystemCompactConfig) error {
	psCmd := p.scriptPath("compact/Invoke-VhdxCompaction.ps1")
	var params string
	if cfg.NoRestart {
		params += " -NoRestart"
	}
	if cfg.Yes {
		params += " -Yes"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Backup(cfg SystemBackupConfig) error {
	psCmd := p.scriptPath("backup/Start-SystemBackup.ps1")
	var params string
	if cfg.BackupFile != "" {
		params += fmt.Sprintf(" -BackupFile '%s'", cfg.BackupFile)
	}
	if cfg.AdditionalHooksDir != "" {
		params += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
	if cfg.SkipPVs {
		params += " -SkipPVs"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Restore(cfg SystemRestoreConfig) error {
	psCmd := p.scriptPath("restore/Start-SystemRestore.ps1")
	var params string
	if cfg.BackupFile != "" {
		params += fmt.Sprintf(" -BackupFile '%s'", cfg.BackupFile)
	}
	if cfg.ErrorOnFailure {
		params += " -ErrorOnFailure"
	}
	if cfg.AdditionalHooksDir != "" {
		params += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) CertificateRenew(cfg SystemCertRenewConfig) error {
	psCmd := p.scriptPath("certificate/renew.ps1")
	var params []string
	if cfg.Force {
		params = append(params, "-Force")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) CertificateAutoRotation(cfg SystemCertAutoRotationConfig) error {
	psCmd := p.scriptPath("certificate/autorotation.ps1")
	var params []string
	if cfg.Enable {
		params = append(params, "-Enable")
	} else if cfg.Disable {
		params = append(params, "-Disable")
	} else {
		params = append(params, "-Status")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

