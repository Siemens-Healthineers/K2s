// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"devgon/cmd"
	"log/slog"
	"os"
)

func main() {
	rootCmd := cmd.Create()

	if err := rootCmd.Execute(); err != nil {
		slog.Error("error occurred while executing the command", "error", err)
		os.Exit(1)
	}
}
