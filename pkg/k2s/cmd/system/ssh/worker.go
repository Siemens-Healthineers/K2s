// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"k2s/utils"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

const (
	CmdToStartShellWorker = "sshw"

	ScriptRelPathToExecuteCmdWorker = "\\smallsetup\\helpers\\sshw.ps1"
)

var sshWorkerCmdExample = `
	# Connect to worker node
	k2s system ssh w

	# Execute a command in worker node
	k2s system ssh w -- echo yes
`

var sshWorkerCmd = &cobra.Command{
	Use:     "w",
	Short:   "Connect to WinNode worker VM",
	Example: sshWorkerCmdExample,
	RunE:    sshWorker,
}

var commandHandlerCreatorFuncForWorker func() commandHandler

type workerBaseCommandProvider struct {
	getInstallDirFunc func() string
}

func (m *workerBaseCommandProvider) getShellCommand() string {
	return CmdToStartShellWorker
}

func (m *workerBaseCommandProvider) getShellExecutorCommand() string {
	return utils.FormatScriptFilePath(m.getInstallDirFunc() + ScriptRelPathToExecuteCmdWorker)
}

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

func sshWorker(cmd *cobra.Command, args []string) error {
	klog.V(3).Infof("Connecting to WinNode worker VM..")

	if err := ensureSetupIsInstalled(); err != nil {
		return err
	}

	parsedArgs, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForWorker()

	handler.Handle(parsedArgs)

	return nil
}
