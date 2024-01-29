// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package multivm

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	ic "k2s/cmd/install/config"
	"k2s/cmd/params"
	"k2s/config"
	"k2s/utils"
	"k2s/utils/tz"
)

type installer interface {
	Install(kind ic.Kind, flags *pflag.FlagSet, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error
}

const (
	kind = "multivm"
)

var (
	example = `
	# install multi-vm setup
	k2s install multivm -i 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
	
	# install multi-vm setup using a user-defined config file
	k2s install multivm -c 'c:\temp\my-config.yaml'
	
	# install multi-vm setup without Windows worker node
	k2s install multivm --linux-only

	# install multi-vm setup overwriting the worker node disk size
	k2s install multivm -i 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso' --worker-disk 120GB
	`
	InstallCmd = &cobra.Command{
		Use:     kind,
		Short:   fmt.Sprintf("Installs '%s' K8s cluster on the host machine", kind),
		RunE:    Install,
		Example: example,
	}

	Installer installer
)

func init() {
	bindFlags(InstallCmd)
}

func bindFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(ic.ImageFlagName, ic.ImageFlagShorthand, "", ic.ImageFlagUsage)

	cmd.Flags().String(params.AdditionalHooksDirFlagName, "", params.AdditionalHooksDirFlagUsage)
	cmd.Flags().BoolP(params.DeleteFilesFlagName, params.DeleteFilesFlagShorthand, false, params.DeleteFilesFlagUsage)
	cmd.Flags().BoolP(params.ForceOnlineInstallFlagName, params.ForceOnlineInstallFlagShorthand, false, params.ForceOnlineInstallFlagUsage)

	cmd.Flags().String(ic.ControlPlaneCPUsFlagName, "", ic.ControlPlaneCPUsFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryFlagName, "", ic.ControlPlaneMemoryFlagUsage)
	cmd.Flags().String(ic.ControlPlaneDiskSizeFlagName, "", ic.ControlPlaneDiskSizeFlagUsage)
	cmd.Flags().StringP(ic.ProxyFlagName, ic.ProxyFlagShorthand, "", ic.ProxyFlagUsage)
	cmd.Flags().StringP(ic.ConfigFileFlagName, ic.ConfigFileFlagShorthand, "", ic.ConfigFileFlagUsage)
	cmd.Flags().Bool(ic.WslFlagName, false, ic.WslFlagUsage)
	cmd.Flags().Bool(ic.LinuxOnlyFlagName, false, ic.LinuxOnlyFlagUsage)
	cmd.Flags().Bool(ic.AppendLogFlagName, false, ic.AppendLogFlagUsage)
	cmd.Flags().Bool(ic.SkipStartFlagName, false, ic.SkipStartFlagUsage)

	cmd.Flags().String(ic.WorkerCPUsFlagName, "", ic.WorkerCPUsFlagUsage)
	cmd.Flags().String(ic.WorkerMemoryFlagName, "", ic.WorkerMemoryFlagUsage)
	cmd.Flags().String(ic.WorkerDiskSizeFlagName, "", ic.WorkerDiskSizeFlagUsage)

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

func Install(cmd *cobra.Command, args []string) error {
	tzConfigHandle, err := createTimezoneConfigHandle()
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	return Installer.Install(kind, cmd.Flags(), buildInstallCmd)
}

func buildInstallCmd(c *ic.InstallConfig) (cmd string, err error) {
	// TODO: remove when implemented
	if c.Behavior.Wsl {
		return "", errors.New("'multivm' setup in combination with WSL is currently not supported")
	}

	controlPlaneNode, err := c.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return "", err
	}

	path := fmt.Sprintf("%s\\smallsetup\\multivm\\Install_MultiVMK8sSetup.ps1", config.SetupRootDir)
	formattedPath := utils.FormatScriptFilePath(path)
	cmd = fmt.Sprintf("%s -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		formattedPath,
		controlPlaneNode.Resources.Cpu,
		controlPlaneNode.Resources.Memory,
		controlPlaneNode.Resources.Disk)

	if c.LinuxOnly {
		cmd += " -LinuxOnly"
	} else {
		workerNode, err := c.GetNodeByRole(ic.WorkerRoleName)
		if err != nil {
			return "", err
		}

		if workerNode.Image == "" {
			return "", fmt.Errorf("missing flag '--%s' or '-%s': %s", ic.ImageFlagName, ic.ImageFlagShorthand, ic.ImageFlagUsage)
		}

		cmd += fmt.Sprintf(" -WinVMProcessorCount %s -WinVMStartUpMemory %s -WinVMDiskSize %s -WindowsImage %s",
			workerNode.Resources.Cpu,
			workerNode.Resources.Memory,
			workerNode.Resources.Disk,
			workerNode.Image)
	}

	if c.Env.Proxy != "" {
		cmd += fmt.Sprintf(" -Proxy %s", c.Env.Proxy)
	}
	if c.Env.AdditionalHooksDir != "" {
		cmd += fmt.Sprintf(" -AdditionalHooksDir '%s'", c.Env.AdditionalHooksDir)
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
	if c.Behavior.AppendLog {
		cmd += " -AppendLogFile"
	}
	if c.Behavior.Wsl {
		cmd += " -WSL"
	}
	return cmd, nil
}
