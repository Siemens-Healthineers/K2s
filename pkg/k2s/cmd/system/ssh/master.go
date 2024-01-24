// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"k2s/cmd/common"
	"k2s/config/defs"
	"k2s/utils"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

const (
	CmdToStartShellMaster = "sshm"

	ScriptRelPathToExecuteCmdMaster = "\\smallsetup\\helpers\\sshm.ps1"
)

var sshMasterCmdExample = `
	# Connect to KubeMaster node
	k2s system ssh m

	# Execute a command in Kubemaster node
	k2s system ssh m -- echo yes
`
var sshMasterCmd = &cobra.Command{
	Use:     "m",
	Short:   "Connect to KubeMaster node",
	Example: sshMasterCmdExample,
	RunE:    sshMaster,
}

var commandHandlerCreatorFuncForMaster func() commandHandler

type masterBaseCommandProvider struct {
	getInstallDirFunc func() string
}

func (m *masterBaseCommandProvider) getShellCommand() string {
	return CmdToStartShellMaster
}

func (m *masterBaseCommandProvider) getShellExecutorCommand() string {
	return utils.FormatScriptFilePath(m.getInstallDirFunc() + ScriptRelPathToExecuteCmdMaster)
}

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

func sshMaster(cmd *cobra.Command, args []string) error {
	klog.V(3).Infof("Connecting to KubeMaster..")

	err := ensureSetupIsInstalled()
	switch err {
	case nil:
		break
	case defs.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	parsedArgs, err := getRemoteCommandToExecute(cmd.ArgsLenAtDash(), args)
	if err != nil {
		return err
	}

	handler := commandHandlerCreatorFuncForMaster()

	handler.Handle(parsedArgs)

	return nil
}
