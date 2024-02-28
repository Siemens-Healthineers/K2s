// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"base/logging"
	"fmt"
	"k2s/setupinfo"
	"path/filepath"
	"time"

	"github.com/pterm/pterm"
)

type FailureSeverity uint8

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
	CliName                  = "k2s"
	ErrSystemNotInstalledMsg = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4
)

var (
	rootLogDir       string
	cliLogPath       string
	executionLogPath string
)

func init() {
	rootLogDir = logging.RootLogDir()
	cliLogPath = filepath.Join(rootLogDir, "cli", fmt.Sprintf("%s.exe.log", CliName))
	executionLogPath = filepath.Join(rootLogDir, "k2s.log")
}

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

func LogFilePath() string {
	return cliLogPath
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", executionLogPath))

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
