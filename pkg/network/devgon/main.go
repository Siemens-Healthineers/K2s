// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"base/logging"
	"devgon/cmd"
	"log/slog"
	"os"
)

func main() {
	var levelVar = new(slog.LevelVar)
	options := &slog.HandlerOptions{
		Level:       levelVar,
		AddSource:   true,
		ReplaceAttr: logging.ReplaceSourceFilePath}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, options)))

	rootCmd := cmd.Create(levelVar)

	if err := rootCmd.Execute(); err != nil {
		slog.Error("error occurred while executing the command", "error", err)
		os.Exit(1)
	}
}
