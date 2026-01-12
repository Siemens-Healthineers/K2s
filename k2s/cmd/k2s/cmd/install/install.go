// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package install

import (
	"fmt"
	"strings"

	"log/slog"
	"os"
	"path/filepath"

	config_contracts "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/buildonly"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/core"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/linuxonly"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

const (
	kind ic.Kind = "k2s"
)

var (
	example = `
	# install K2s setup (online/offline - depending on offline files existence)
	k2s install

	# install K2s setup overwriting control-plane memory
	k2s install --master-memory 8GB

	# install without Windows worker node
	k2s install --linux-only

	# install K2s setup setting a proxy
	k2s install --proxy http://10.11.12.13:5000

	# install K2s setup setting a proxy with no-proxy hosts
	k2s install --proxy http://10.11.12.13:5000 --no-proxy localhost,127.0.0.1,.local

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
	installer             common.Installer
	createTzHandleFunc    func(config *config_contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error)
	buildLinuxOnlyCmdFunc func(config *ic.InstallConfig) (cmd string, err error)
)

func init() {
	InstallCmd.AddCommand(buildonly.InstallCmd)

	installer = &core.Installer{
		InstallConfigAccess:      ic.NewInstallConfigAccess(),
		Printer:                  terminal.NewTerminalPrinter(),
		ExecutePsScript:          powershell.ExecutePs,
		GetVersionFunc:           version.GetVersion,
		GetPlatformFunc:          utils.Platform,
		GetInstallDirFunc:        utils.InstallDir,
		LoadConfigFunc:           config.ReadRuntimeConfig,
		MarkSetupAsCorruptedFunc: config.MarkSetupAsCorrupted,
		DeleteConfigFunc: func(configDir string) error {
			return os.Remove(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName))
		},
	}

	buildonly.Installer = installer
	createTzHandleFunc = createTimezoneConfigHandle
	buildLinuxOnlyCmdFunc = linuxonly.BuildCmd

	bindFlags(InstallCmd)
}

func bindFlags(cmd *cobra.Command) {
	cmd.Flags().String(cc.AdditionalHooksDirFlagName, "", cc.AdditionalHooksDirFlagUsage)
	cmd.Flags().BoolP(cc.DeleteFilesFlagName, cc.DeleteFilesFlagShorthand, false, cc.DeleteFilesFlagUsage)
	cmd.Flags().BoolP(cc.ForceOnlineInstallFlagName, cc.ForceOnlineInstallFlagShorthand, false, cc.ForceOnlineInstallFlagUsage)

	cmd.Flags().String(ic.ControlPlaneCPUsFlagName, "", ic.ControlPlaneCPUsFlagUsage)
	cmd.Flags().String(ic.ControlPlaneMemoryFlagName, "", ic.ControlPlaneMemoryFlagUsage)
	cmd.Flags().String(ic.ControlPlaneDiskSizeFlagName, "", ic.ControlPlaneDiskSizeFlagUsage)
	cmd.Flags().StringP(ic.ProxyFlagName, ic.ProxyFlagShorthand, "", ic.ProxyFlagUsage)
	cmd.Flags().StringSlice(ic.NoProxyFlagName, []string{}, ic.NoProxyFlagUsage)
	cmd.Flags().StringP(ic.ConfigFileFlagName, ic.ConfigFileFlagShorthand, "", ic.ConfigFileFlagUsage)
	cmd.Flags().Bool(ic.WslFlagName, false, ic.WslFlagUsage)
	cmd.Flags().String(ic.K8sBinFlagName, "", ic.K8sBinFlagUsage)

	// convenience flag; not configurable in config file
	cmd.Flags().Bool(ic.LinuxOnlyFlagName, false, ic.LinuxOnlyFlagUsage)

	cmd.Flags().Bool(ic.AppendLogFlagName, false, ic.AppendLogFlagUsage)
	cmd.Flags().Bool(ic.SkipStartFlagName, false, ic.SkipStartFlagUsage)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func createTimezoneConfigHandle(config *config_contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error) {
	tzConfigWorkspace, err := tz.NewTimezoneConfigWorkspace(config)
	if err != nil {
		return nil, err
	}
	tzConfigHandle, err := tzConfigWorkspace.CreateHandle()
	if err != nil {
		return nil, err
	}
	return tzConfigHandle, nil
}

func findExecutablesInPath(exeName string) ([]string, error) {
	pathEnv := os.Getenv("PATH")
	if pathEnv == "" {
		return nil, nil
	}
	var found []string
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" || dir == "." {
			continue
		}
		exePath := filepath.Join(dir, exeName)
		absExePath, err := filepath.Abs(exePath)
		if err != nil {
			continue
		}
		if info, err := os.Stat(absExePath); err == nil && !info.IsDir() {
			found = append(found, absExePath)
		}
	}
	return found, nil
}

func checkForOldK2sExecutables(currentExe string, exeName string) ([]string, error) {
	currentExeAbs, _ := filepath.Abs(currentExe)
	paths, err := findExecutablesInPath(exeName)
	if err != nil {
		return nil, fmt.Errorf("[Install] Error scanning PATH for %s: %v", exeName, err)
	}
	var otherK2s []string
	for _, p := range paths {
		absP, _ := filepath.Abs(p)
		if !strings.EqualFold(absP, currentExeAbs) {
			otherK2s = append(otherK2s, absP)
		}
	}
	return otherK2s, nil
}

func install(cmd *cobra.Command, args []string) error {
	exeName := "k2s.exe"
    currentExe, err := os.Executable()
    if err != nil {
    	return fmt.Errorf("[Install] Error: unable to determine current executable path: %v", err)
    }
    otherK2s, err := checkForOldK2sExecutables(currentExe, exeName)
    if err != nil {
    	return err
    }
    if len(otherK2s) > 0 {
    	fmt.Println("[Install] Found older k2s executables:")
    	for _, p := range otherK2s {
    		fmt.Fprintf(os.Stderr, "  %s\n", p)
    	}
    	return fmt.Errorf("Please clean up your PATH environment variable to remove old k2s.exe locations before proceeding with installation.")
    }

	cmdSession := cc.StartCmdSession(cmd.CommandPath())
	linuxOnly, err := cmd.Flags().GetBool(ic.LinuxOnlyFlagName)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)

	tzConfigHandle, err := createTzHandleFunc(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	buildCmdFunc := buildInstallCmd

	if linuxOnly {
		slog.Info("Switching to Linux-only")

		buildCmdFunc = buildLinuxOnlyCmdFunc
	}

	return installer.Install(kind, cmd, buildCmdFunc, cmdSession)
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
	if len(c.Env.NoProxy) > 0 {
		cmd += fmt.Sprintf(" -NoProxy '%s'", strings.Join(c.Env.NoProxy, "','"))
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
