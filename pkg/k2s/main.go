// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"fmt"
	"k2s/cmd"
	"k2s/cmd/common"
	"k2s/utils/logging"
	"log/slog"
	"os"

	"github.com/pterm/pterm"
)

func main() {
	exitCode := 0

	defer func() {
		logging.Finalize()
		os.Exit(exitCode)
	}()

	levelVar := logging.Initialize()

	rootCmd, err := cmd.CreateRootCmd(levelVar)
	if err != nil {
		exitCode = 1
		slog.Error("error occurred during root command creation", "error", err)
		return
	}

	err = rootCmd.Execute()
	if err == nil {
		return
	}

	exitCode = 1

	var cmdFailure *common.CmdFailure
	if !errors.As(err, &cmdFailure) {
		pterm.Error.Println(err)
		slog.Error("error occurred during command execution", "error", err)
		return
	}

	if !cmdFailure.SuppressCliOutput {
		switch cmdFailure.Severity {
		case common.SeverityWarning:
			pterm.Warning.Println(cmdFailure.Message)
		case common.SeverityError:
			pterm.Error.Println(cmdFailure.Message)
		default:
			slog.Warn("unknown cmd failure severity", "severity", cmdFailure.Severity)
		}
	}

	logging.DisableCliOutput()

	slog.Error("command failed",
		"severity", fmt.Sprintf("%d(%s)", cmdFailure.Severity, cmdFailure.Severity),
		"code", cmdFailure.Code,
		"message", cmdFailure.Message,
		"suppressCliOutput", cmdFailure.SuppressCliOutput)
}
