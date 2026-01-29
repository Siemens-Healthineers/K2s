// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package add

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
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
	MachineWindows            = "windows"
	MachineWindowsFlagUsage   = "Specify if the node is a Windows machine"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "[EXPERIMENTAL] Add a node to the cluster",
		Long:  "Adds an machine or VM to an existing K2s cluster",
		RunE:  addNode,
	}
	cmd.Flags().StringP(MachineIPAddress, "i", "", MachineIPAddressFlagUsage)
	cmd.Flags().StringP(MachineUsername, "u", "", MachineUsernameFlagUsage)
	cmd.Flags().StringP(MachineName, "m", "", MachineNameFlagUsage)
	cmd.Flags().StringP(MachineRole, "r", "worker", MachineRoleFlagUsage)
	cmd.Flags().BoolP(MachineWindows, "w", false, MachineWindowsFlagUsage)
	cmd.MarkFlagRequired(MachineIPAddress)
	cmd.MarkFlagRequired(MachineUsername)
	cmd.MarkFlagsRequiredTogether(MachineIPAddress, MachineUsername)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func addNode(ccmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(ccmd.CommandPath())
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

	systemStatus, err := status.LoadStatus()
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	addNodeCmd, err := buildAddNodeCmd(ccmd.Flags(), runtimeConfig.InstallConfig().SetupName())
	if err != nil {
		return err
	}

	pterm.Printfln("🤖 Adding node to K2s cluster")
	slog.Debug("PS command created", "command", addNodeCmd)

	err = powershell.ExecutePs(addNodeCmd, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildAddNodeCmd(flags *pflag.FlagSet, setupName string) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if setupName != definitions.SetupNameK2s {
		return "", errors.New("adding node is not supported for this setup type. Aborting")
	}
	isWindows := flags.Lookup(MachineWindows).Value.String() == "true"
	cmd := ""
	if isWindows {
		cmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\worker\\windows\\windows-host\\Add.ps1")
	} else {
		cmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\worker\\linux\\bare-metal\\Add.ps1")
	}

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
