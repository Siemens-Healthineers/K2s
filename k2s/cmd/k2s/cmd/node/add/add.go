// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package add

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	MachineName               = "name"
	MachineNameFlagUsage      = "Hostname of the machine"
	MachineIPAddress          = "ip-addr"
	MachineIPAddressFlagUsage = "IP Address of the machine"
	MachineUsername           = "username"
	MachineUsernameFlagUsage  = "Username of the machine for remote connection"
	MachineRole               = "role"
	MachineRoleFlagUsage      = "Role of the machine as a node"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "[EXPERIMENTAL] Add a node to the cluster",
		Long:  "Adds an machine or VM to an existing K2s cluster",
		RunE:  addNode,
	}
	cmd.Flags().String(MachineIPAddress, "", MachineIPAddressFlagUsage)
	cmd.Flags().String(MachineUsername, "", MachineUsernameFlagUsage)
	cmd.Flags().String(MachineName, "", MachineNameFlagUsage)
	cmd.Flags().String(MachineRole, "worker", MachineRoleFlagUsage)

	cmd.MarkFlagRequired(MachineIPAddress)
	cmd.MarkFlagRequired(MachineUsername)
	cmd.MarkFlagsRequiredTogether(MachineIPAddress, MachineUsername)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func addNode(ccmd *cobra.Command, args []string) error {
	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	psVersion := common.DeterminePsVersion(config)
	systemStatus, err := status.LoadStatus(psVersion)
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	addNodeCmd, err := buildAddNodeCmd(ccmd.Flags(), config.SetupName)
	if err != nil {
		return err
	}

	pterm.Printfln("🤖 Adding node to K2s cluster")
	slog.Debug("PS command created", "command", addNodeCmd)

	start := time.Now()

	err = powershell.ExecutePs(addNodeCmd, psVersion, common.NewPtermWriter())
	if err != nil {
		return err
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, "Add Node")

	return nil
}

func buildAddNodeCmd(flags *pflag.FlagSet, setupName setupinfo.SetupName) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if setupName != setupinfo.SetupNamek2s {
		return "", errors.New("adding node is not supported for this setup type. Aborting")
	}

	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\worker\\linux\\bare-metal\\Add.ps1")

	if outputFlag {
		cmd += " -ShowLogs"
	}

	// TODO: usage of role

	machineUserName := flags.Lookup(MachineUsername).Value.String()
	machineIpAddress := flags.Lookup(MachineIPAddress).Value.String()
	machineName := flags.Lookup(MachineName).Value.String()

	cmd += " -UserName " + machineUserName
	cmd += " -IpAddress " + machineIpAddress

	if machineName != "" {
		cmd += " -NodeName " + machineName
	}

	return cmd, nil
}
