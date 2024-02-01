// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"github.com/pterm/pterm"
)

func PrintAddonNotFoundMsg(dir string, name string) {
	pterm.Warning.Printfln("Addon '%s' not found in directory '%s'", name, dir)
}

func PrintNoAddonStatusMsg(name string) {
	pterm.Info.Printfln("Addon '%s' does not provide detailed status information", name)
}
