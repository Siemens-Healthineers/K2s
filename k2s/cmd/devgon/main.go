// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"log/slog"
	"os"

	"github.com/siemens-healthineers/k2s/cmd/devgon/cmd"

	"github.com/siemens-healthineers/k2s/internal/logging"
)

func main() {
	var levelVar = new(slog.LevelVar)
	options := &slog.HandlerOptions{
		Level:       levelVar,
		AddSource:   true,
		ReplaceAttr: logging.ShortenSourceAttribute}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, options)))

	rootCmd := cmd.Create(levelVar)

	if err := rootCmd.Execute(); err != nil {
		slog.Error("error occurred while executing the command", "error", err)
		os.Exit(1)
	}
}
