// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"base/logging"
	"fmt"
	"path/filepath"
	"time"

	"github.com/pterm/pterm"
)

const (
	CliName = "k2s"
)

var rootLogDir string
var cliLogPath string
var executionLogPath string

func init() {
	rootLogDir = logging.RootLogDir()
	cliLogPath = filepath.Join(rootLogDir, "cli", fmt.Sprintf("%s.exe.log", CliName))
	executionLogPath = filepath.Join(rootLogDir, "k2s.log")
}

func LogFilePath() string {
	return cliLogPath
}

func PrintCompletedMessage(duration time.Duration, command string) {
	pterm.Success.Printfln("'%s' completed in %v", command, duration)

	logHint := pterm.LightCyan(fmt.Sprintf("Please see '%s' for more information", executionLogPath))

	pterm.Println(logHint)
}

func PrintNotInstalledMessage() {
	pterm.Info.Println("You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first")
}
