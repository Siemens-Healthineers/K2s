// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/pterm/pterm"
)

type FailureSeverity uint8
type ContextKey string

type Spinner interface {
	Stop() error
}

type TerminalPrinter interface {
	StartSpinner(m ...any) (any, error)
}

type CmdFailure struct {
	Severity          FailureSeverity `json:"severity"`
	Code              string          `json:"code"`
	Message           string          `json:"message"`
	SuppressCliOutput bool
}

type CmdResult struct {
	Failure *CmdFailure `json:"error"`
}

const (
	ErrSystemNotInstalledMsg = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4

	ContextKeyConfigDir ContextKey = "config"
)

func (c *CmdFailure) Error() string {
	return fmt.Sprintf("%s: %s", c.Code, c.Message)
}

func (s FailureSeverity) String() string {
	switch s {
	case SeverityWarning:
		return "warning"
	case SeverityError:
		return "error"
	default:
		return "unknown"
	}
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", logging.PsLogPath()))

	pterm.Println(logHint)
}

func CreateSystemNotInstalledCmdResult() CmdResult {
	return CmdResult{Failure: CreateSystemNotInstalledCmdFailure()}
}

func CreateSystemNotInstalledCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     setupinfo.ErrSystemNotInstalled.Error(),
		Message:  ErrSystemNotInstalledMsg,
	}
}

func StartSpinner(printer TerminalPrinter) (Spinner, error) {
	startResult, err := printer.StartSpinner("Gathering information..")
	if err != nil {
		return nil, err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return nil, errors.New("could not start operation")
	}

	return spinner, nil
}

func StopSpinner(spinner Spinner) {
	if err := spinner.Stop(); err != nil {
		slog.Error("spinner stop", "error", err)
	}
}
