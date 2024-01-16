// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"k2s/cmd"
	"k2s/utils/logging"

	"github.com/pterm/pterm"
)

func main() {
	defer logging.Finalize()

	if err := cmd.Execute(); err != nil {
		pterm.Error.Println(err)
		logging.Exit(err)
	}
}
