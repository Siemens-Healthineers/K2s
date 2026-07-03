// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/provider"

	"github.com/pterm/pterm"
)

func main() {
	enableVirtualTerminalProcessing()

	exitCode := cli.ExitCodeSuccess

	logger := logging.NewSlogger()

	defer func() {
		if err := recover(); err != nil {
			exitCode = cli.ExitCodeFailure
			handleUnexpectedError(err)
		}

		logger.Flush()
		logger.Close()
		os.Exit(int(exitCode))
	}()

	rootCmd, err := cmd.CreateRootCmd(logger)
	if err != nil {
		exitCode = cli.ExitCodeFailure
		slog.Error("error occurred during root command creation", "error", err)
		return
	}

	err = rootCmd.Execute()
	if err == nil {
		return
	}

	exitCode = cli.ExitCodeFailure

	var cmdFailure *common.CmdFailure
	if errors.As(err, &cmdFailure) {
		handleCmdFailure(cmdFailure.Severity, cmdFailure.Code, cmdFailure.Message, cmdFailure.SuppressCliOutput)
		return
	}

	var providerFailure *provider.ProviderFailure
	if errors.As(err, &providerFailure) {
		handleCmdFailure(common.FailureSeverity(providerFailure.Severity), providerFailure.Code, providerFailure.Message, providerFailure.SuppressCliOutput)
		return
	}

	handleUnexpectedError(err)
}

func handleCmdFailure(severity common.FailureSeverity, code string, message string, suppressCliOutput bool) {
	if !suppressCliOutput {
		switch severity {
		case common.SeverityWarning:
			pterm.Warning.Println(message)
		case common.SeverityError:
			pterm.Error.Println(message)
		default:
			slog.Warn("unknown cmd failure severity", "severity", severity)
		}
	}

	slog.Error("command failed",
		"severity", fmt.Sprintf("%d(%s)", severity, severity),
		"code", code,
		"message", message,
		"suppressCliOutput", suppressCliOutput)
}

func handleUnexpectedError(err any) {
	pterm.Error.Println(fmt.Errorf("%v", err))

	slog.Error("unexpected error", "error", err)
}
