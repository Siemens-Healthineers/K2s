// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package stop

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	cc "github.com/siemens-healthineers/k2s/internal/core/clusterconfig"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/provider"
)

var Stopk8sCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stops K2s cluster on the host machine",
	RunE:  stopk8s,
}

func init() {
	Stopk8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	Stopk8sCmd.Flags().BoolP(common.CacheVSwitchFlagName, "", false, common.CacheVSwitchFlagUsage)
	Stopk8sCmd.Flags().SortFlags = false
	Stopk8sCmd.Flags().PrintDefaults()
}

func stopk8s(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Printfln("🛑 Stopping K2s cluster")

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
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

	err = stopAdditionalNodes(context, cmd.Flags())
	if err != nil {
		// Stop of additional nodes shall not impact the k2s cluster stop, any errors during stop should be treated as warnings.
		slog.Warn("Failures during stopping of additional nodes", "err", err)
	}

	// Read flags
	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	cacheVSwitches, err := strconv.ParseBool(cmd.Flags().Lookup(common.CacheVSwitchFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	setupName := runtimeConfig.InstallConfig().SetupName()
	linuxOnly := runtimeConfig.InstallConfig().LinuxOnly()

	// Stop cluster via provider (handles platform dispatch)
	err = context.Providers().Cluster.Stop(provider.ClusterStopConfig{
		ShowLogs:           outputFlag,
		AdditionalHooksDir: additionalHooksDir,
		CacheVSwitch:       cacheVSwitches,
		SetupName:          setupName,
		LinuxOnly:          linuxOnly,
	})
	if err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}

func stopAdditionalNodes(context *common.CmdContext, flags *pflag.FlagSet) error {
	systemStatus, err := status.LoadStatus(context)
	if err != nil || !systemStatus.RunningState.IsRunning {
		// Nothing to do if system is not running
		return nil
	}

	clusterConfig, err := cc.Read(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if clusterConfig == nil {
		return nil
	}

	for _, node := range clusterConfig.Nodes {
		startNodeCmd := buildNodeStopCmd(flags, node)

		slog.Debug("PS command created", "command", startNodeCmd)

		err = powershell.ExecutePs(startNodeCmd, common.NewPtermWriter())
		if err != nil {
			slog.Warn("Failure during stop of node", "node", node.Name, "err", err)
		}
	}

	return nil
}

func buildNodeStopCmd(flags *pflag.FlagSet, nodeConfig cc.Node) string {
	outputFlag, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	roleType := string(nodeConfig.Role)
	OsType := string(nodeConfig.OS)
	nodeType := cc.GetNodeDirectory(string(nodeConfig.NodeType))

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", roleType, OsType, nodeType, "Stop.ps1"))

	if outputFlag {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if nodeConfig.Name != "" {
		cmd += " -NodeName " + nodeConfig.Name
	}

	return cmd
}
