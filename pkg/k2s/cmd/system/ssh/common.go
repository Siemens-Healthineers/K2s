// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	"k2s/config"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"log/slog"
	"os"
	"os/exec"
	"strings"
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
		if err := ensureSetupIsInstalled(); err != nil {
			return err
		}

		sshCmd := exec.Command(proc)
		sshCmd.Stdin = os.Stdin
		sshCmd.Stdout = os.Stdout
		sshCmd.Stderr = os.Stderr
		return sshCmd.Run()
	}

	cmdOverSshExecFunc func(baseCmd, cmd string) error = func(baseCmd, cmd string) error {
		cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](
			baseCmd,
			"CmdResult",
			psexecutor.ExecOptions{NoProgress: true},
			"-Command",
			fmt.Sprintf("\"%s\"", cmd))
		if err != nil {
			return err
		}

		if cmdResult.Failure != nil {
			return cmdResult.Failure
		}
		return nil
	}

	k2sInstallDirProviderFunc = func() string {
		return utils.GetInstallationDirectory()
	}
)

func (r *remoteCommandHandler) Handle(cmd string) error {
	var err error
	if cmd == "" {
		err = r.startShell()
	} else {
		err = r.executeCommand(cmd)
	}
	if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
		return common.CreateSystemNotInstalledCmdFailure()
	}
	return err
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
			slog.Debug("No args provided. Will proceed to start the shell.")
			return "", nil
		} else {
			return "", fmt.Errorf("unknown option: %s", args[0])
		}
	}

	if len(args) == 0 {
		return "", errors.New("no command provided to execute")
	}

	cmdToExecute := strings.Join(args[0:], " ")

	slog.Debug("PS command created", "command", cmdToExecute)

	return cmdToExecute, nil
}

func ensureSetupIsInstalled() error {
	ca := config.NewAccess()

	_, err := ca.GetSetupName()

	return err
}
