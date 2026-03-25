// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package start

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/config"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cc "github.com/siemens-healthineers/k2s/internal/core/clusterconfig"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/provider"
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

	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	skipStartIfRunning, err := HandleIgnoreIfRunning(ccmd, func() (bool, error) {
		return isClusterRunning(context)
	})
	if err != nil {
		return err
	}
	if skipStartIfRunning {
		cmdSession.Finish()
		return nil
	}

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

	tzConfigHandle, err := createTimezoneConfigHandle(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	// Read flags
	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := ccmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	autouseCachedVSwitch, err := strconv.ParseBool(ccmd.Flags().Lookup(common.AutouseCachedVSwitchFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	setupName := runtimeConfig.InstallConfig().SetupName()
	linuxOnly := runtimeConfig.InstallConfig().LinuxOnly()

	// Start cluster via provider (handles platform dispatch)
	err = context.Providers().Cluster.Start(provider.ClusterStartConfig{
		ShowLogs:            outputFlag,
		AdditionalHooksDir:  additionalHooksDir,
		UseCachedK2sVSwitch: autouseCachedVSwitch,
		SetupName:           setupName,
		LinuxOnly:           linuxOnly,
	})
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

func isClusterRunning(ctx *common.CmdContext) (bool, error) {

	clusterStatus, err := status.LoadStatus(ctx)
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

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", roleType, OsType, nodeType, "Start.ps1"))

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
