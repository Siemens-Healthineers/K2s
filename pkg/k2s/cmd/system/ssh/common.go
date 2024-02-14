// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	"k2s/utils"
	"os"
	"os/exec"
	"strings"

	"k8s.io/klog/v2"
)

type commandHandler interface {
	Handle(cmd string) error
}

type baseCommandProvider interface {
	getShellCommand() string
	getShellExecutorCommand() string
}

type remoteCommandHandler struct {
	baseCommandProvider baseCommandProvider
	processExecFunc     func(proc string) error
	commandExecFunc     func(baseCmd, cmd string) error
}

var (
	sshExecFunc func(proc string) error = func(proc string) error {
		sshCmd := exec.Command(proc)
		sshCmd.Stdin = os.Stdin
		sshCmd.Stdout = os.Stdout
		sshCmd.Stderr = os.Stderr
		return sshCmd.Run()
	}

	cmdOverSshExecFunc func(baseCmd, cmd string) error = func(baseCmd, cmd string) error {
		cmdResult, err := utils.ExecutePsWithStructuredResult[*common.CmdResult](
			baseCmd,
			"CmdResult",
			utils.ExecOptions{NoProgress: true},
			"-Command",
			fmt.Sprintf("\"%s\"", cmd))
		if err != nil {
			return err
		}

		if cmdResult.Error != nil {
			return cmdResult.Error.ToError()
		}
		return nil
	}

	k2sInstallDirProviderFunc = func() string {
		return utils.GetInstallationDirectory()
	}
)

func (r *remoteCommandHandler) Handle(cmd string) error {
	if cmd == "" {
		return r.startShell()
	}
	return r.executeCommand(cmd)
}

func (r *remoteCommandHandler) startShell() error {
	shell := r.baseCommandProvider.getShellCommand()

	return r.processExecFunc(shell)
}

func (r *remoteCommandHandler) executeCommand(cmd string) error {
	baseCommand := r.baseCommandProvider.getShellExecutorCommand()

	return r.commandExecFunc(baseCommand, cmd)
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
