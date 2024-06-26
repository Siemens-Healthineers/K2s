// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/spf13/cobra"
)

type masterBaseCommandProvider struct {
	getInstallDirFunc func() string
}

const (
	cmdToStartShellMaster           = "sshm"
	scriptRelPathToExecuteCmdMaster = "\\lib\\scripts\\k2s\\system\\ssh\\sshm.ps1"
)

var (
	sshMasterCmdExample = `
	# Connect to KubeMaster node
	k2s system ssh m

	# Execute a command in Kubemaster node
	k2s system ssh m -- echo yes
`
	sshMasterCmd = &cobra.Command{
		Use:     "m",
		Short:   "Connect to KubeMaster node",
		Example: sshMasterCmdExample,
		RunE:    sshMaster,
	}

	commandHandlerCreatorFuncForMaster func() commandHandler
)

func init() {
	sshMasterCmd.Flags().SortFlags = false
	sshMasterCmd.Flags().PrintDefaults()

	commandHandlerCreatorFuncForMaster = func() commandHandler {
		return &remoteCommandHandler{
			baseCommandProvider: &masterBaseCommandProvider{
				getInstallDirFunc: k2sInstallDirProviderFunc,
			},
			processExecFunc: sshExecFunc,
			commandExecFunc: cmdOverSshExecFunc,
		}
	}
}

func (m *masterBaseCommandProvider) getShellCommand() string {
	return cmdToStartShellMaster
}

func (m *masterBaseCommandProvider) getShellExecutorCommand() string {
	return utils.FormatScriptFilePath(m.getInstallDirFunc() + scriptRelPathToExecuteCmdMaster)
}

func sshMaster(cmd *cobra.Command, args []string) error {
	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	slog.Info("Connecting to Linux node")

	remoteCmd, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForMaster()

	return handler.Handle(remoteCmd, common.DeterminePsVersion(config))
}
