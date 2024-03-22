// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell

import (
	"fmt"
	"log/slog"
	"os/exec"
)

type PowerShellVersion string

const (
	PowerShellV5      PowerShellVersion = "5"
	PowerShellV7      PowerShellVersion = "7"
	DefaultPsVersions PowerShellVersion = PowerShellV5
)

func AssertPowerShellV7Installed() error {
	_, err := exec.LookPath(string(Ps7CmdName))
	if err == nil {
		slog.Debug("PowerShell 7 is installed")
		return nil
	}

	// TODO: could be nicer :-)
	return fmt.Errorf("%s\nPlease install Powershell 7: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows", err)
}
