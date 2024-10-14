// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/spf13/cobra"
)

type workerBaseCommandProvider struct {
	getInstallDirFunc func() string
}

const (
	cmdToStartShellWorker           = "sshw"
	scriptRelPathToExecuteCmdWorker = "\\lib\\scripts\\multivm\\system\\ssh\\sshw.ps1"
)

var (
	sshWorkerCmdExample = `
	# Connect to worker node
	k2s system ssh w

	# Execute a command in worker node
	k2s system ssh w -- echo yes
`

	sshWorkerCmd = &cobra.Command{
		Use:     "w",
		Short:   "Connect to WinNode worker VM",
		Example: sshWorkerCmdExample,
		RunE:    sshWorker,
	}

	commandHandlerCreatorFuncForWorker func() commandHandler
)

func init() {
	sshMasterCmd.Flags().SortFlags = false
	sshMasterCmd.Flags().PrintDefaults()

	commandHandlerCreatorFuncForWorker = func() commandHandler {
		return &remoteCommandHandler{
			baseCommandProvider: &workerBaseCommandProvider{
				getInstallDirFunc: k2sInstallDirProviderFunc,
			},
			processExecFunc: sshExecFunc,
			commandExecFunc: cmdOverSshExecFunc,
		}
	}
}

func (m *workerBaseCommandProvider) getShellCommand() string {
	return cmdToStartShellWorker
}

func (m *workerBaseCommandProvider) getShellExecutorCommand() string {
	return utils.FormatScriptFilePath(m.getInstallDirFunc() + scriptRelPathToExecuteCmdWorker)
}

func sshWorker(cmd *cobra.Command, args []string) error {
	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	slog.Info("Connecting to WinNode worker VM")

	remoteCmd, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForWorker()

	return handler.Handle(remoteCmd, common.DeterminePsVersion(config))
}
