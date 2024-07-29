// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type commandHandler interface {
	Handle(cmd string, psVersion powershell.PowerShellVersion) error
}

type baseCommandProvider interface {
	getShellCommand() string
	getShellExecutorCommand() string
}

type remoteCommandHandler struct {
	baseCommandProvider baseCommandProvider
	processExecFunc     func(proc string) error
	commandExecFunc     func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error
}

var (
	sshExecFunc func(proc string) error = func(proc string) error {
		sshCmd := exec.Command(proc)
		sshCmd.Stdin = os.Stdin
		sshCmd.Stdout = os.Stdout
		sshCmd.Stderr = os.Stderr
		return sshCmd.Run()
	}

	cmdOverSshExecFunc func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error = func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error {
		outputWriter := common.NewPtermWriter()
		outputWriter.ShowProgress = false

		cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](
			baseCmd,
			"CmdResult",
			psVersion,
			outputWriter,
			"-Command",
			utils.EscapeWithDoubleQuotes(utils.EscapeWithDoubleQuotes(cmd))) //must be escaped doubled to be invoked properly from central Invoke-ExecScript.ps1
		if err != nil {
			return err
		}

		if cmdResult.Failure != nil {
			return cmdResult.Failure
		}
		return nil
	}

	k2sInstallDirProviderFunc = func() string {
		return utils.InstallDir()
	}
)

func (r *remoteCommandHandler) Handle(cmd string, psVersion powershell.PowerShellVersion) error {
	if cmd == "" {
		return r.startShell(psVersion)
	}
	return r.executeCommand(cmd, psVersion)
}

func (r *remoteCommandHandler) startShell(psVersion powershell.PowerShellVersion) error {
	baseCommand := r.baseCommandProvider.getShellExecutorCommand()

	err := r.commandExecFunc(baseCommand, "echo Connecting...", psVersion)
	if err != nil {
		return err
	}

	shell := r.baseCommandProvider.getShellCommand()
	return r.processExecFunc(shell)
}

func (r *remoteCommandHandler) executeCommand(cmd string, psVersion powershell.PowerShellVersion) error {
	baseCommand := r.baseCommandProvider.getShellExecutorCommand()

	return r.commandExecFunc(baseCommand, cmd, psVersion)
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
