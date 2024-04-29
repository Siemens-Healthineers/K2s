// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"errors"
	"fmt"
	"log/slog"
	"time"

	kl "github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	"github.com/siemens-healthineers/k2s/internal/logging"
	"github.com/siemens-healthineers/k2s/internal/powershell"

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

type OutputWriter struct {
	ShowProgress    bool
	errorLineBuffer *logging.LogBuffer
	ErrorOccurred   bool
}

const (
	ErrSystemNotInstalledMsg     = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"
	ErrSystemInCorruptedStateMsg = "Errors occurred during K2s setup. K2s cluster is in corrupted state. Please uninstall and reinstall K2s cluster."

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4

	ContextKeyConfigDir ContextKey = "config"

	OutputFlagName      = "output"
	OutputFlagShorthand = "o"
	OutputFlagUsage     = "Show all logs in terminal"

	AdditionalHooksDirFlagName  = "additional-hooks-dir"
	AdditionalHooksDirFlagUsage = "Directory containing additional hooks to be executed"

	DeleteFilesFlagName      = "delete-files-for-offline-installation"
	DeleteFilesFlagShorthand = "d"
	DeleteFilesFlagUsage     = "After an online installation delete the files that are needed for an offline installation"

	ForceOnlineInstallFlagName      = "force-online-installation"
	ForceOnlineInstallFlagShorthand = "f"
	ForceOnlineInstallFlagUsage     = "Force the online installation"

	AutouseCachedVSwitchFlagName  = "autouse-cached-vswitch"
	AutouseCachedVSwitchFlagUsage = "Automatically utilizes the cached vSwitch 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine"

	CacheVSwitchFlagName  = "cache-vswitch"
	CacheVSwitchFlagUsage = "Cache vswitches 'cbr0' and 'KubeSwitch' for cluster connectivity through the host machine."
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

func (o *OutputWriter) WriteStd(line string) {
	if o.ShowProgress {
		pterm.Printfln("⏳ %s", line)
	} else {
		pterm.Println(line)
	}
}

func (o *OutputWriter) WriteErr(line string) {
	o.errorLineBuffer.Log(line)
	o.ErrorOccurred = true

	pterm.Printfln("⏳ %s", pterm.Yellow(line))
}

func (o *OutputWriter) Flush() {
	o.errorLineBuffer.Flush()
}

func NewOutputWriter() (*OutputWriter, error) {
	errorLineBuffer, err := createErrorLineBuffer()
	if err != nil {
		return nil, err
	}

	return &OutputWriter{
		ShowProgress:    true,
		errorLineBuffer: errorLineBuffer}, nil
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", kl.PsLogPath()))

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

func CreateSystemInCorruptedStateCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     setupinfo.ErrSystemInCorruptedState.Error(),
		Message:  ErrSystemInCorruptedStateMsg,
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

func DeterminePsVersion(config *setupinfo.Config) powershell.PowerShellVersion {
	if config.SetupName == setupinfo.SetupNameMultiVMK8s && !config.LinuxOnly {
		return powershell.PowerShellV7
	}

	return powershell.PowerShellV5
}

func createErrorLineBuffer() (*logging.LogBuffer, error) {
	return logging.NewLogBuffer(logging.BufferConfig{
		Limit: 100,
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
}
