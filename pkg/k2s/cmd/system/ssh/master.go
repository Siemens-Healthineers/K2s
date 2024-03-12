// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"k2s/utils"
	"log/slog"

	"github.com/spf13/cobra"
)

type masterBaseCommandProvider struct {
	getInstallDirFunc func() string
}

const (
	cmdToStartShellMaster           = "sshm"
	scriptRelPathToExecuteCmdMaster = "\\smallsetup\\helpers\\sshm.ps1"
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
	slog.Info("Connecting to Linux node")

	remoteCmd, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForMaster()

	return handler.Handle(remoteCmd)
}
