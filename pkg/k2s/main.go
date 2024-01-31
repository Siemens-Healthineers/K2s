// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"k2s/cmd"
	"k2s/setupinfo"
	"k2s/status"
	"k2s/utils/logging"

	"github.com/pterm/pterm"
)

func main() {
	defer logging.Finalize()

	if err := cmd.Execute(); err != nil {
		if errors.Is(err, setupinfo.ErrNotInstalled) {
			pterm.Info.Println("You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first")
			return
		}
		if errors.Is(err, status.ErrNotRunning) {
			pterm.Info.Println("K2s is not running. To interact with the system, please start it with 'k2s start' first")
		}

		pterm.Error.Println(err)
		logging.Exit(err)
	}
}
