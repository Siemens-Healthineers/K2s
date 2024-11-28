// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	bl "github.com/siemens-healthineers/k2s/internal/logging"
	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

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

type PtermWriter struct {
	ShowProgress    bool
	errorLineBuffer *bl.LogBuffer
	ErrorOccurred   bool
	ErrorLines      []string
}

type SlogWriter struct {
}

type CmdContext struct {
	config *config.Config
	logger *logging.Slogger
}

const (
	ErrSystemNotInstalledMsg     = "You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first"
	ErrSystemInCorruptedStateMsg = "Errors occurred during K2s setup. K2s cluster is in corrupted state. Please uninstall and reinstall K2s cluster."
	ErrSystemNotRunningMsg       = "The system is stopped. Run 'k2s start' to start the system."

	SeverityWarning FailureSeverity = 3
	SeverityError   FailureSeverity = 4

	ContextKeyCmdContext ContextKey = "cmd-context"

	OutputFlagName      = "output"
	OutputFlagShorthand = "o"
	OutputFlagUsage     = "Show log in terminal"

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

func NewPtermWriter() *PtermWriter {
	return &PtermWriter{
		ShowProgress:    true,
		errorLineBuffer: createErrorLineBuffer(),
	}
}

func NewSlogWriter() os.StdWriter { return &SlogWriter{} }

func NewCmdContext(config *config.Config, logger *logging.Slogger) *CmdContext {
	return &CmdContext{
		config: config,
		logger: logger,
	}
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", bl.GlobalLogFilePath()))

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

func CreateSystemNotRunningCmdFailure() *CmdFailure {
	return &CmdFailure{
		Severity: SeverityWarning,
		Code:     "system-not-running",
		Message:  ErrSystemNotRunningMsg,
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

func GetDefaultPsVersion() powershell.PowerShellVersion { return powershell.PowerShellV5 }

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

func (c *CmdFailure) Error() string { return fmt.Sprintf("%s: %s", c.Code, c.Message) }

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

func (w *PtermWriter) WriteStdOut(line string) {
	if w.ShowProgress {
		pterm.Printfln("⏳ %s", line)
	} else {
		pterm.Println(line)
	}
}

func (w *PtermWriter) WriteStdErr(line string) {
	w.errorLineBuffer.Log(line)
	w.ErrorOccurred = true
	w.ErrorLines = append(w.ErrorLines, line)

	pterm.Printfln("⏳ %s", pterm.Yellow(line))
}

func (w *PtermWriter) Flush() { w.errorLineBuffer.Flush() }

func (*SlogWriter) WriteStdOut(message string) { slog.Info(message) }

func (*SlogWriter) WriteStdErr(message string) { slog.Error(message) }

func (*SlogWriter) Flush() { /*empty*/ }

func (c *CmdContext) Config() *config.Config { return c.config }

func (c *CmdContext) Logger() *logging.Slogger { return c.logger }

func createErrorLineBuffer() *bl.LogBuffer {
	return bl.NewLogBuffer(bl.BufferConfig{
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
}
