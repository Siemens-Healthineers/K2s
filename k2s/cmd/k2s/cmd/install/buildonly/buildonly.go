// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package buildonly

import (
	"fmt"

	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/common"
	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/spf13/cobra"
)

const (
	kind = "buildonly"
)

var (
	example = `
	# install build-only setup
	k2s install buildonly
	
	# install build-only setup using a user-defined config file
	k2s install buildonly -c 'c:\temp\my-config.yaml'
	`
	InstallCmd = &cobra.Command{
		Use:     kind,
		Short:   fmt.Sprintf("Installs '%s' setup on the host machine", kind),
		RunE:    install,
		Example: example,
	}

	Installer common.Installer
)

func init() {
	bindFlags(InstallCmd)
}

func bindFlags(cmd *cobra.Command) {
	cmd.Flags().BoolP(cc.DeleteFilesFlagName, cc.DeleteFilesFlagShorthand, false, cc.DeleteFilesFlagUsage)
	cmd.Flags().BoolP(cc.ForceOnlineInstallFlagName, cc.ForceOnlineInstallFlagShorthand, false, cc.ForceOnlineInstallFlagUsage)

	cmd.Flags().String(ic.ControlPlaneCPUsFlagName, "", ic.ControlPlaneCPUsFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryFlagName, "", ic.ControlPlaneMemoryFlagUsage)
	cmd.Flags().String(ic.ControlPlaneDiskSizeFlagName, "", ic.ControlPlaneDiskSizeFlagUsage)
	cmd.Flags().StringP(ic.ProxyFlagName, ic.ProxyFlagShorthand, "", ic.ProxyFlagUsage)
	cmd.Flags().StringP(ic.ConfigFileFlagName, ic.ConfigFileFlagShorthand, "", ic.ConfigFileFlagUsage)
	cmd.Flags().Bool(ic.WslFlagName, false, ic.WslFlagUsage)
	cmd.Flags().Bool(ic.AppendLogFlagName, false, ic.AppendLogFlagUsage)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func install(cmd *cobra.Command, args []string) error {
	cmdSession := cc.StartCmdSession(cmd.CommandPath())

	return Installer.Install(kind, cmd, buildInstallCmd, cmdSession)
}

func buildInstallCmd(c *ic.InstallConfig) (cmd string, err error) {
	controlPlaneNode, err := c.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return "", err
	}

	path := fmt.Sprintf("%s\\lib\\scripts\\buildonly\\install\\install.ps1", utils.InstallDir())
	formattedPath := utils.FormatScriptFilePath(path)
	cmd = fmt.Sprintf("%s -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		formattedPath,
		controlPlaneNode.Resources.Cpu,
		controlPlaneNode.Resources.Memory,
		controlPlaneNode.Resources.Disk)

	if c.Env.Proxy != "" {
		cmd += fmt.Sprintf(" -Proxy %s", c.Env.Proxy)
	}
	if c.Behavior.ShowOutput {
		cmd += " -ShowLogs"
	}
	if c.Behavior.DeleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}
	if c.Behavior.ForceOnlineInstallation {
		cmd += " -ForceOnlineInstallation"
	}
	if c.Behavior.Wsl {
		cmd += " -WSL"
	}
	if c.Behavior.AppendLog {
		cmd += " -AppendLogFile"
	}
	return cmd, nil
}
