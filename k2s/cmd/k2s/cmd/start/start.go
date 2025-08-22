// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package start

import (
	"errors"
	"log/slog"
	"strconv"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/config"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cc "github.com/siemens-healthineers/k2s/internal/core/clusterconfig"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

var Startk8sCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts K2s cluster on the host machine",
	RunE:  startk8s,
}

func init() {
	Startk8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	Startk8sCmd.Flags().BoolP(common.AutouseCachedVSwitchFlagName, "", false, common.AutouseCachedVSwitchFlagUsage)
	Startk8sCmd.Flags().BoolP(common.IgnoreIfRunningFlagName, common.IgnoreIfRunningFlagShort, false, common.IgnoreIfRunningFlagUsage)
	Startk8sCmd.Flags().SortFlags = false
	Startk8sCmd.Flags().PrintDefaults()
}

func startk8s(ccmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(ccmd.CommandPath())
	pterm.Printfln("🤖 Starting K2s on %s", utils.Platform())

	skipStartIfRunning, err := HandleIgnoreIfRunning(ccmd, isClusterRunning)
	if err != nil {
		return err
	}
	if skipStartIfRunning {
		cmdSession.Finish()
		return nil
	}

	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	startCmd, err := buildStartCmd(ccmd.Flags(), runtimeConfig)
	if err != nil {
		return err
	}

	tzConfigHandle, err := createTimezoneConfigHandle(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	slog.Debug("PS command created", "command", startCmd)

	err = powershell.ExecutePs(startCmd, common.NewPtermWriter())
	if err != nil {
		return err
	}

	err = startAdditionalNodes(context, ccmd.Flags(), runtimeConfig)
	if err != nil {
		// Start of additional nodes shall not impact the k2s cluster, any errors during startup should be treated as warnings.
		slog.Warn("Failures during starting of additional nodes", "err", err)
	}

	cmdSession.Finish()

	return nil
}

func startAdditionalNodes(context *common.CmdContext, flags *pflag.FlagSet, config *cconfig.K2sRuntimeConfig) error {
	clusterConfig, err := cc.Read(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if clusterConfig == nil {
		return nil
	}

	for _, node := range clusterConfig.Nodes {
		startNodeCmd := buildNodeStartCmd(flags, node)

		slog.Debug("PS command created", "command", startNodeCmd)

		err = powershell.ExecutePs(startNodeCmd, common.NewPtermWriter())
		if err != nil {
			slog.Warn("Failure during start of node", "node", node.Name, "err", err)
		}
	}

	return nil
}

func isClusterRunning() (bool, error) {

	clusterStatus, err := status.LoadStatus()
	if err != nil {
		slog.Error("Failed to load cluster status", "error", err)
		return false, err
	}

	if clusterStatus != nil && clusterStatus.RunningState.IsRunning {
		return clusterStatus.RunningState != nil && clusterStatus.RunningState.IsRunning, nil
	}

	return false, nil
}

func HandleIgnoreIfRunning(ccmd *cobra.Command, clusterIsRunning func() (bool, error)) (bool, error) {
	ignoreIfRunning, err := strconv.ParseBool(ccmd.Flags().Lookup(common.IgnoreIfRunningFlagName).Value.String())
	if err != nil {
		return false, err
	}

	if ignoreIfRunning {
		isRunning, err := clusterIsRunning()
		if err != nil {
			return false, err
		}
		if isRunning {
			pterm.Printfln("🚀 K2s cluster is already running. Skipping start.")
			return true, nil
		}
	}

	return false, nil
}

func buildNodeStartCmd(flags *pflag.FlagSet, nodeConfig cc.Node) string {
	outputFlag, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	roleType := string(nodeConfig.Role)
	OsType := string(nodeConfig.OS)
	nodeType := cc.GetNodeDirectory(string(nodeConfig.NodeType))

	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\" + roleType + "\\" + OsType + "\\" + nodeType + "\\Start.ps1")

	if outputFlag {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if nodeConfig.IpAddress != "" {
		cmd += " -IpAddress " + nodeConfig.IpAddress
	}

	if nodeConfig.Name != "" {
		cmd += " -NodeName " + nodeConfig.Name
	}

	return cmd
}

func buildStartCmd(flags *pflag.FlagSet, config *cconfig.K2sRuntimeConfig) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	autouseCachedVSwitch, err := strconv.ParseBool(flags.Lookup(common.AutouseCachedVSwitchFlagName).Value.String())
	if err != nil {
		return "", err
	}

	var cmd string

	switch config.InstallConfig().SetupName() {
	case definitions.SetupNameK2s:
		if config.InstallConfig().LinuxOnly() {
			cmd = buildLinuxOnlyStartCmd(outputFlag, additionalHooksDir)
		} else {
			cmd = buildk2sStartCmd(outputFlag, additionalHooksDir, autouseCachedVSwitch)
		}
	case definitions.SetupNameBuildOnlyEnv:
		return "", errors.New("there is no cluster to start in build-only setup mode ;-). Aborting")
	default:
		return "", errors.New("could not determine the setup type, aborting. If you are sure you have a K2s setup installed, call the correct start script directly")
	}

	return cmd, nil
}

func buildk2sStartCmd(showLogs bool, additionalHooksDir string, autouseCachedVSwitch bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\k2s\\start\\start.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if autouseCachedVSwitch {
		cmd += " -UseCachedK2sVSwitches"
	}

	return cmd
}

func buildLinuxOnlyStartCmd(showLogs bool, additionalHooksDir string) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\linuxonly\\start\\start.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	return cmd
}

func createTimezoneConfigHandle(config *contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error) {
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
