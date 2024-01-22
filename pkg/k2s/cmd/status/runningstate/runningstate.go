// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package runningstate

import (
	"errors"
	"k2s/cmd/status/load"
)

type TerminalPrinter interface {
	PrintSuccess(m ...any)
	PrintInfoln(m ...any)
	PrintTreeListItems(items []string)
}

type RunningStatePrinter struct {
	terminalPrinter TerminalPrinter
}

func NewRunningStatePrinter(terminalPrinter TerminalPrinter) RunningStatePrinter {
	return RunningStatePrinter{terminalPrinter: terminalPrinter}
}

func (rs RunningStatePrinter) PrintRunningState(runningState *load.RunningState) (bool, error) {
	if runningState == nil {
		return false, errors.New("no running state info retrieved")
	}

	if runningState.IsRunning {
		rs.terminalPrinter.PrintSuccess("The cluster is running")

		return true, nil
	}

	rs.terminalPrinter.PrintInfoln("The cluster is not running. Run 'k2s start' to start the cluster")
	rs.terminalPrinter.PrintTreeListItems(runningState.Issues)

	return false, nil
}
