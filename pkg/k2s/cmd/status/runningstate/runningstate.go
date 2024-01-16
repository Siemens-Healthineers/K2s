// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package runningstate

import (
	"k2s/cmd/status/load"
)

type TerminalPrinter interface {
	PrintSuccess(m ...any)
	PrintWarning(m ...any)
	PrintTreeListItems(items []string)
}

type RunningStatePrinter struct {
	terminalPrinter TerminalPrinter
}

func NewRunningStatePrinter(terminalPrinter TerminalPrinter) RunningStatePrinter {
	return RunningStatePrinter{terminalPrinter: terminalPrinter}
}

func (rs RunningStatePrinter) PrintRunningState(runningState load.RunningState) (proceed bool) {
	if runningState.IsRunning {
		rs.terminalPrinter.PrintSuccess("The cluster is running")

		return true
	} else {
		rs.terminalPrinter.PrintWarning("The cluster is not running. Run 'k2s start' to start the cluster")
		rs.terminalPrinter.PrintTreeListItems(runningState.Issues)

		return false
	}
}
