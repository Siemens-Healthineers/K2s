// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package cmdexecutor

type CmdExecutor interface {
	ExecCmd(cliArgs ...string) *CmdExecStatus
}

type CmdExecStatus struct {
	Ok     bool
	Output string
	Err    error
}
