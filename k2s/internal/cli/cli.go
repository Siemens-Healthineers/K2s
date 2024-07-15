// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cli

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/logging"
)

const (
	VerbosityFlagName      = "verbosity"
	VerbosityFlagShorthand = "v"
)

func VerbosityFlagHelp() string {
	debug := logging.LevelToLowerString(slog.LevelDebug)
	info := logging.LevelToLowerString(slog.LevelInfo)
	warn := logging.LevelToLowerString(slog.LevelWarn)
	err := logging.LevelToLowerString(slog.LevelError)

	return "log level/verbosity, either pre-defined levels, integer values or a combination of both.\n" +
		fmt.Sprintf("Pre-defined levels: %s = %d | %s = %d | %s = %d | %s = %d\n", debug, slog.LevelDebug, info, slog.LevelInfo, warn, slog.LevelWarn, err, slog.LevelError) +
		fmt.Sprintf("- e.g. '-v %s'\t-> %s\n", debug, debug) +
		fmt.Sprintf("- e.g. '-v %d'\t-> %s\n", slog.LevelWarn, warn) +
		fmt.Sprintf("- e.g. '-v %s+4'\t-> %s\n", debug, info) +
		fmt.Sprintf("- e.g. '-v %s-8'\t-> %s\n", err, info) +
		fmt.Sprintf("- e.g. '-v %s+2'\t-> %d (between %s and %s)\n", warn, slog.LevelWarn+2, warn, err)
}
