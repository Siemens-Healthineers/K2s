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
<<<<<<< HEAD
	psCmd := p.scriptPath("dump/dump.ps1")
	var params string
	if cfg.SkipOpenDump {
		params += " -OpenDumpFolder `$false"
	}
=======
	psCmd := p.scriptPath("dump/Dump-Status.ps1")
	var params string
>>>>>>> main
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Upgrade(cfg SystemUpgradeConfig) error {
<<<<<<< HEAD
	psCmd := p.scriptPath("upgrade/Start-ClusterUpgrade.ps1")
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	if cfg.SkipResources {
		params += " -SkipResources"
=======
	psCmd := p.scriptPath("upgrade/Start-ClusterUpdate.ps1")
	var params string
	if cfg.PackagePath != "" {
		params += fmt.Sprintf(" -ZipFilePath '%s'", cfg.PackagePath)
>>>>>>> main
	}
	if cfg.SkipImages {
		params += " -SkipImages"
	}
<<<<<<< HEAD
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
=======
	if cfg.ForceOnline {
		params += " -ForceOnlineInstallation"
	}
	if cfg.DeletePackage {
		params += " -DeleteFiles"
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
>>>>>>> main
	}
	if cfg.AdditionalHooksDir != "" {
		params += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
<<<<<<< HEAD
	if cfg.Force {
		params += " -Force"
	}
=======
>>>>>>> main
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
<<<<<<< HEAD
	psCmd := p.scriptPath("reset/Reset-System.ps1")
=======
	psCmd := p.scriptPath("reset/Reset.ps1")
>>>>>>> main
	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) ResetNetwork(cfg SystemResetNetworkConfig) error {
<<<<<<< HEAD
	psCmd := p.scriptPath("reset/network/Reset-Network.ps1")
	var params []string
	if cfg.Force {
		params = append(params, " -Force")
	}
=======
	psCmd := p.scriptPath("reset/Reset-Network.ps1")
	var params []string
>>>>>>> main
	if cfg.AdditionalHooksDir != "" {
		params = append(params, fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir))
	}
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
	}
	return p.execPS(psCmd, params...)
}

func (p *windowsSystemProvider) Compact(cfg SystemCompactConfig) error {
<<<<<<< HEAD
	psCmd := p.scriptPath("compact/Invoke-VhdxCompaction.ps1")
	var params string
	if cfg.NoRestart {
		params += " -NoRestart"
	}
	if cfg.Yes {
		params += " -Yes"
	}
=======
	psCmd := p.scriptPath("compact/Compact-Vhdx.ps1")
	var params string
>>>>>>> main
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Backup(cfg SystemBackupConfig) error {
<<<<<<< HEAD
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
=======
	psCmd := p.scriptPath("backup/Backup.ps1")
	var params string
	if cfg.BackupDir != "" {
		params += fmt.Sprintf(" -BackupDir '%s'", cfg.BackupDir)
>>>>>>> main
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) Restore(cfg SystemRestoreConfig) error {
<<<<<<< HEAD
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
=======
	psCmd := p.scriptPath("restore/Restore.ps1")
	var params string
	if cfg.BackupDir != "" {
		params += fmt.Sprintf(" -BackupDir '%s'", cfg.BackupDir)
>>>>>>> main
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}
	return powershell.ExecutePs(psCmd+params, p.stdWriter)
}

func (p *windowsSystemProvider) CertificateRenew(cfg SystemCertRenewConfig) error {
<<<<<<< HEAD
	psCmd := p.scriptPath("certificate/renew.ps1")
	var params []string
	if cfg.Force {
		params = append(params, "-Force")
	}
	if cfg.ShowOutput {
		params = append(params, "-ShowLogs")
=======
	psCmd := p.scriptPath("certificate/Renew-Certificate.ps1")
	var params []string
	if cfg.ShowOutput {
		params = append(params, " -ShowLogs")
>>>>>>> main
	}
	return p.execPS(psCmd, params...)
}
