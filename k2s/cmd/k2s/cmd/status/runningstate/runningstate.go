// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package runningstate

import (
	"errors"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"
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

func (rs RunningStatePrinter) PrintRunningState(runningState *common.RunningState) (bool, error) {
	if runningState == nil {
		return false, errors.New("no running state info retrieved")
	}

	if runningState.IsRunning {
		rs.terminalPrinter.PrintSuccess("The system is running")

		return true, nil
	}

	rs.terminalPrinter.PrintInfoln("The system is not running. Run 'k2s start' to start the system")
	rs.terminalPrinter.PrintTreeListItems(runningState.Issues)

	return false, nil
}
