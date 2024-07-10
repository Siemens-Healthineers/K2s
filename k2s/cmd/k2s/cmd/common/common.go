// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	ul "github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"

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

type PsCommandOutputWriter struct {
	ShowProgress    bool
	errorLineBuffer *logging.LogBuffer
	ErrorOccurred   bool
	ErrorLines      []string
}

type ExecOutputWriter struct {
	*ul.Slogger
}

const (
	ErrSystemNotInstalledMsg     = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"
	ErrSystemInCorruptedStateMsg = "Errors occurred during K2s setup. K2s cluster is in corrupted state. Please uninstall and reinstall K2s cluster."

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4

	ContextKeyConfig ContextKey = "config"

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

	PreReqMarker = "[PREREQ-FAILED]"
)

func NewPsCommandOutputWriter() *PsCommandOutputWriter {
	return &PsCommandOutputWriter{
		ShowProgress:    true,
		errorLineBuffer: createErrorLineBuffer(),
	}
}

func NewExecOutputWriter(showOutputOnCli bool) *ExecOutputWriter {
	builders := []ul.HandlerBuilder{ul.NewFileHandler(logging.GlobalLogFilePath())}

	if showOutputOnCli {
		builders = append(builders, ul.NewCliPtermHandler())
	}

	logger := ul.NewSlogger().SetHandlers(builders...)
	logger.LevelVar.Set(slog.LevelInfo)

	return &ExecOutputWriter{Slogger: logger}
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", logging.GlobalLogFilePath()))

	pterm.Println(logHint)
}

func CreateSystemNotInstalledCmdResult() CmdResult {
	return CmdResult{Failure: CreateSystemNotInstalledCmdFailure()}
}

func CreateSystemInCorruptedStateCmdResult() CmdResult {
	return CmdResult{Failure: CreateSystemInCorruptedStateCmdFailure()}
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
		Severity: SeverityError,
		Code:     setupinfo.ErrSystemInCorruptedState.Error(),
		Message:  ErrSystemInCorruptedStateMsg,
	}
}

func CreateSystemUnableToUpgradeCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityError,
		Code:     "unable-to-upgrade",
		Message:  "'k2s system upgrade' failed",
	}
}

func CreateFunctionalityNotAvailableCmdFailure(setupName setupinfo.SetupName) *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     "functionality-not-available",
		Message:  fmt.Sprintf("This functionality is not available because '%s' setup is deprecated.", setupName),
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

func GetDefaultPsVersion() powershell.PowerShellVersion {
	return powershell.PowerShellV5
}

func GetInstallPreRequisiteError(errorLines []string) (line string, found bool) {
	for _, line := range errorLines {
		if strings.Contains(line, PreReqMarker) {
			// Remove error line with pre-requisite marker e.g [PREREQ-FAILED] Master node memory passed too low
			cleanedLine := strings.Replace(line, PreReqMarker, "", -1)
			cleanedLine = strings.Replace(cleanedLine, " ", "", 1)
			return cleanedLine, true
		}
	}

	return "", false
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

func (o *PsCommandOutputWriter) WriteStdOut(line string) {
	if o.ShowProgress {
		pterm.Printfln("⏳ %s", line)
	} else {
		pterm.Println(line)
	}
}

func (o *PsCommandOutputWriter) WriteStdErr(line string) {
	o.errorLineBuffer.Log(line)
	o.ErrorOccurred = true
	o.ErrorLines = append(o.ErrorLines, line)

	pterm.Printfln("⏳ %s", pterm.Yellow(line))
}

func (o *PsCommandOutputWriter) Flush() {
	o.errorLineBuffer.Flush()
}

func (w *ExecOutputWriter) WriteStdOut(message string) {
	w.Logger.Info(message)
}

func (w *ExecOutputWriter) WriteStdErr(message string) {
	w.Logger.Error(message)
}

func createErrorLineBuffer() *logging.LogBuffer {
	return logging.NewLogBuffer(logging.BufferConfig{
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
}
