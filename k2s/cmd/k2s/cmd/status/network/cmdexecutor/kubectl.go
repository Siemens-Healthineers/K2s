// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package cmdexecutor

import (
	"os/exec"
	"path/filepath"
)

type CommandRunner func(name string, arg ...string) ([]byte, error)

type Kubectl struct {
	cliPath       string
	commandRunner CommandRunner
}

func NewKubectlCli(rootDir string) *Kubectl {
	cliPath := filepath.Join(rootDir, "bin", "exe", "kubectl.exe")

	return &Kubectl{
		cliPath:       cliPath,
		commandRunner: defaultCommandRunner,
	}
}

func NewKubectlCliWithRunner(rootDir string, runner CommandRunner) *Kubectl {
	cliPath := filepath.Join(rootDir, "bin", "exe", "kubectl.exe")

	return &Kubectl{
		cliPath:       cliPath,
		commandRunner: runner,
	}
}

func defaultCommandRunner(name string, arg ...string) ([]byte, error) {
	cmd := exec.Command(name, arg...)
	return cmd.CombinedOutput()
}

func (k *Kubectl) ExecCmd(args ...string) *CmdExecStatus {
	output, err := k.commandRunner(k.cliPath, args...)
	return &CmdExecStatus{
		Ok:     err == nil,
		Output: string(output),
		Err:    err,
	}
}
