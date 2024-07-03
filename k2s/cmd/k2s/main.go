// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"runtime/debug"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"

	"github.com/pterm/pterm"
)

func main() {
	exitCode := 0

	defer func() {
		if err := recover(); err != nil {
			exitCode = 1
			handleUnexpectedError(err)
		}

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
		pterm.Error.Println(fmt.Errorf("%v", err))
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

func handleUnexpectedError(err any) {
	pterm.Error.Println(fmt.Errorf("%v", err))
	slog.Error("error", err, "stack", string(debug.Stack()))
}
