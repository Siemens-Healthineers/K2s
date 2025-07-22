// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package remove

import (
	"errors"
	"log/slog"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	MachineName          = "name"
	MachineNameFlagUsage = "Hostname of the machine"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "remove",
		Short: "[EXPERIMENTAL] Remove a node from the cluster",
		Long:  "Removes machine or VM from K2s cluster",
		RunE:  removeNode,
	}
	cmd.Flags().StringP(MachineName, "m", "", MachineNameFlagUsage)
	cmd.MarkFlagsOneRequired(MachineName)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func removeNode(ccmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(ccmd.CommandPath())
	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host().K2sConfigDir())
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := context.EnsureK2sK8sContext(config.ClusterName); err != nil {
		return err
	}

	addNodeCmd, err := buildRemoveNodeCmd(ccmd.Flags(), config.SetupName)
	if err != nil {
		return err
	}

	pterm.Printfln("🤖 Removing node from K2s cluster")
	slog.Debug("PS command created", "command", addNodeCmd)

	err = powershell.ExecutePs(addNodeCmd, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildRemoveNodeCmd(flags *pflag.FlagSet, setupName setupinfo.SetupName) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if setupName != setupinfo.SetupNamek2s {
		return "", errors.New("removing node is not supported for this setup type. Aborting")
	}

	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\worker\\linux\\bare-metal\\Remove.ps1")

	if outputFlag {
		cmd += " -ShowLogs"
	}

	machineName := flags.Lookup(MachineName).Value.String()

	if machineName != "" {
		cmd += " -NodeName " + machineName
	}

	return cmd, nil
}
