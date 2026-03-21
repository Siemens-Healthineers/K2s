// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package install

import (
	"fmt"
	"log/slog"
	"os"

	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setuporchestration"
	"github.com/siemens-healthineers/k2s/internal/version"
	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

// installLinux handles K2s installation natively on a Linux host.
// It bypasses the PowerShell orchestration and uses kubeadm/systemd directly.
func installLinux(cmd *cobra.Command, installConfig *ic.InstallConfig) error {
	cmdSession := cc.StartCmdSession(cmd.CommandPath())

	ver := version.GetVersion()
	pterm.Printfln("🤖 Installing K2s '%s' %s on %s (native Linux)", kind, ver, utils.Platform())

	hostname, _ := os.Hostname()

	orchestrator := setuporchestration.NewOrchestrator(nil)

	cfg := setuporchestration.InstallConfig{
		ShowLogs:                installConfig.Behavior.ShowOutput,
		LinuxOnly:               installConfig.LinuxOnly,
		WSL:                     installConfig.Behavior.Wsl,
		ForceOnlineInstallation: installConfig.Behavior.ForceOnlineInstallation,
		Proxy:                   installConfig.Env.Proxy,
		AdditionalHooksDir:      installConfig.Env.AdditionalHooksDir,
		ConfigDir:               host.K2sConfigDir(),
		InstallDir:              utils.InstallDir(),
		Version:                 fmt.Sprintf("%s", ver),
		ClusterName:             "k2s-cluster",
		ControlPlaneHostname:    hostname,
	}

	// Map VM resource config if available
	node, err := installConfig.GetNodeByRole(ic.ControlPlaneRoleName)
	if err == nil {
		cfg.MasterVMProcessorCount = node.Resources.Cpu
		cfg.MasterVMMemory = node.Resources.Memory
		cfg.MasterDiskSize = node.Resources.Disk
	}

	slog.Info("Starting native Linux installation", "config", cfg)

	if err := orchestrator.Install(cfg); err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}
