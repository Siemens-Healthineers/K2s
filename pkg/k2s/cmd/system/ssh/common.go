// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"fmt"
	"k2s/config"
	"k2s/utils"
	"os"
	"os/exec"
	"strings"

	"k8s.io/klog/v2"
)

const cmdExecuteFormat = "%s -Command \"%s\""

var sshExecFunc func(proc string) = func(proc string) {
	sshCmd := exec.Command(proc)
	sshCmd.Stdin = os.Stdin
	sshCmd.Stdout = os.Stdout
	sshCmd.Stderr = os.Stderr
	sshCmd.Run()
}

var cmdOverSshExecFunc func(cmd string) = func(cmd string) {
	utils.ExecutePowershellScript(cmd, utils.ExecOptions{NoProgress: true})
}

var k2sInstallDirProviderFunc = func() string {
	return utils.GetInstallationDirectory()
}

type commandHandler interface {
	Handle(args string)
}

type baseCommandProvider interface {
	getShellCommand() string
	getShellExecutorCommand() string
}

type remoteCommandHandler struct {
	baseCommandProvider baseCommandProvider
	processExecFunc     func(proc string)
	commandExecFunc     func(cmd string)
}

func (r *remoteCommandHandler) Handle(args string) {
	if args == "" {
		r.startShell()
	} else {
		r.executeCommand(args)
	}
}

func (r *remoteCommandHandler) startShell() {
	shell := r.baseCommandProvider.getShellCommand()

	r.processExecFunc(shell)
}

func (r *remoteCommandHandler) executeCommand(cmd string) {
	baseCommand := r.baseCommandProvider.getShellExecutorCommand()
	cmdToExecute := fmt.Sprintf(cmdExecuteFormat, baseCommand, cmd)
	r.commandExecFunc(cmdToExecute)
}

func getRemoteCommandToExecute(argsLenAtDash int, args []string) (string, error) {
	if argsLenAtDash == -1 {
		if len(args) == 0 {
			klog.V(5).Infoln("No args provided. Will proceed to start the shell.")
			return "", nil
		} else {
			return "", fmt.Errorf("unknown option: %s", args[0])
		}
	}

	if len(args) == 0 {
		return "", errors.New("no command provided to execute")
	}

	cmdToExecute := strings.Join(args[0:], " ")
	klog.V(5).Infof("Command to execute : %s", cmdToExecute)

	return cmdToExecute, nil
}

func ensureSetupIsInstalled() error {
	ca := config.NewAccess()

	_, err := ca.GetSetupName()

	return err
}
