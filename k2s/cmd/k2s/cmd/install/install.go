// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package install

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/buildonly"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/core"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/multivm"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

type Installer interface {
	Install(kind ic.Kind, cmd *cobra.Command, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error
}

const (
	kind ic.Kind = "k2s"
)

var (
	example = `
	# install K2s setup (online/offline - depending on offline files existence)
	k2s install

	# install K2s setup overwriting control-plane memory
	k2s install --master-memory 8GB

	# install multi-vm setup without Windows worker node (effectively without Windows VM)
	k2s install --linux-only
	Note: same effect as running 'k2s install multivm --linux-only'

	# install K2s setup setting a proxy
	k2s install --proxy http://10.11.12.13:5000

	# install K2s setup using a user-defined config file
	k2s install -c 'c:\temp\my-config.yaml'

	# install K2s setup using a user-defined config file overwriting the control-plane CPU number
	k2s install -c 'c:\temp\my-config.yaml' --master-cpus 4

	# install K2s setup deleting the downloaded files for subsequent offline installations
	k2s install --delete-files-for-offline-installation

	# install K2s setup forcing an online installation, i.e. downloading files
	k2s install --force-online-installation
	`

	InstallCmd = &cobra.Command{
		Use:     "install",
		Short:   fmt.Sprintf("Installs '%s' K8s cluster on the host machine", kind),
		RunE:    install,
		Example: example,
	}

	installer          Installer
	installMultiVmFunc func(cmd *cobra.Command, args []string) error
	createTzHandleFunc func() (tz.ConfigWorkspaceHandle, error)
)

func init() {
	InstallCmd.AddCommand(multivm.InstallCmd)
	InstallCmd.AddCommand(buildonly.InstallCmd)

	installer = &core.Installer{
		InstallConfigAccess:       ic.NewInstallConfigAccess(),
		Printer:                   terminal.NewTerminalPrinter(),
		ExecutePsScript:           powershell.ExecutePs,
		GetVersionFunc:            version.GetVersion,
		GetPlatformFunc:           utils.Platform,
		GetInstallDirFunc:         utils.InstallDir,
		PrintCompletedMessageFunc: common.PrintCompletedMessage,
		LoadConfigFunc:            setupinfo.ReadConfig,
		SetConfigFunc:             setupinfo.WriteConfig,
		DeleteConfigFunc:          setupinfo.DeleteConfig,
	}

	multivm.Installer = installer
	buildonly.Installer = installer
	installMultiVmFunc = multivm.Install
	createTzHandleFunc = createTimezoneConfigHandle

	bindFlags(InstallCmd)
}

func bindFlags(cmd *cobra.Command) {
	cmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	cmd.Flags().BoolP(common.DeleteFilesFlagName, common.DeleteFilesFlagShorthand, false, common.DeleteFilesFlagUsage)
	cmd.Flags().BoolP(common.ForceOnlineInstallFlagName, common.ForceOnlineInstallFlagShorthand, false, common.ForceOnlineInstallFlagUsage)

	cmd.Flags().String(ic.ControlPlaneCPUsFlagName, "", ic.ControlPlaneCPUsFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryFlagName, "", ic.ControlPlaneMemoryFlagUsage)
	cmd.Flags().String(ic.ControlPlaneDiskSizeFlagName, "", ic.ControlPlaneDiskSizeFlagUsage)
	cmd.Flags().StringP(ic.ProxyFlagName, ic.ProxyFlagShorthand, "", ic.ProxyFlagUsage)
	cmd.Flags().StringP(ic.ConfigFileFlagName, ic.ConfigFileFlagShorthand, "", ic.ConfigFileFlagUsage)
	cmd.Flags().Bool(ic.WslFlagName, false, ic.WslFlagUsage)
	cmd.Flags().String(ic.K8sBinFlagName, "", ic.K8sBinFlagUsage)

	// convenience flag; not configurable in config file; leads to multivm setup if true
	cmd.Flags().Bool(ic.LinuxOnlyFlagName, false, ic.LinuxOnlyFlagUsage)

	cmd.Flags().Bool(ic.AppendLogFlagName, false, ic.AppendLogFlagUsage)
	cmd.Flags().Bool(ic.SkipStartFlagName, false, ic.SkipStartFlagUsage)
	cmd.Flags().String(ic.RestartFlagName, "", ic.RestartFlagUsage)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func createTimezoneConfigHandle() (tz.ConfigWorkspaceHandle, error) {
	tzConfigWorkspace, err := tz.NewTimezoneConfigWorkspace()
	if err != nil {
		return nil, err
	}
	tzConfigHandle, err := tzConfigWorkspace.CreateHandle()
	if err != nil {
		return nil, err
	}
	return tzConfigHandle, nil
}

func install(cmd *cobra.Command, args []string) error {
	linuxOnly, err := cmd.Flags().GetBool(ic.LinuxOnlyFlagName)
	if err != nil {
		return err
	}

	tzConfigHandle, err := createTzHandleFunc()
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	if linuxOnly {
		slog.Info("Switching setup type due to flag setting", "type", ic.MultivmConfigType, "flag", ic.LinuxOnlyFlagName)

		if err := installMultiVmFunc(cmd, args); err != nil {
			return err
		}
		return nil
	}

	return installer.Install(kind, cmd, buildInstallCmd)
}

func buildInstallCmd(c *ic.InstallConfig) (cmd string, err error) {
	node, err := c.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return "", err
	}

	path := utils.InstallDir() + "\\lib\\scripts\\k2s\\install\\install.ps1"
	formattedPath := utils.FormatScriptFilePath(path)
	cmd = fmt.Sprintf("%s -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		formattedPath,
		node.Resources.Cpu,
		node.Resources.Memory,
		node.Resources.Disk)

	if c.Env.Proxy != "" {
		cmd += " -Proxy " + c.Env.Proxy
	}
	if c.Env.AdditionalHooksDir != "" {
		cmd += fmt.Sprintf(" -AdditionalHooksDir '%s'", c.Env.AdditionalHooksDir)
	}
	if c.Env.RestartPostInstall != "" {
		cmd += fmt.Sprintf(" -RestartAfterInstallCount %s", c.Env.RestartPostInstall)
	}
	if c.Env.K8sBins != "" {
		cmd += fmt.Sprintf(" -K8sBinsPath '%s'", c.Env.K8sBins)
	}
	if c.Behavior.ShowOutput {
		cmd += " -ShowLogs"
	}
	if c.Behavior.SkipStart {
		cmd += " -SkipStart"
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
