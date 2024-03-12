// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"k2s/utils"
	"log/slog"

	"github.com/spf13/cobra"
)

type workerBaseCommandProvider struct {
	getInstallDirFunc func() string
}

const (
	cmdToStartShellWorker           = "sshw"
	scriptRelPathToExecuteCmdWorker = "\\smallsetup\\helpers\\sshw.ps1"
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
	slog.Info("Connecting to WinNode worker VM")

	remoteCmd, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForWorker()

	return handler.Handle(remoteCmd)
}
