// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell

import "github.com/siemens-healthineers/k2s/internal/setupinfo"

type PowerShellVersion string

const (
	PowerShellV5      PowerShellVersion = "5"
	PowerShellV7      PowerShellVersion = "7"
	DefaultPsVersions PowerShellVersion = PowerShellV5
	Ps5CmdName                          = "powershell"
	Ps7CmdName                          = "pwsh"
)

func DeterminePsVersion(config *setupinfo.Config) PowerShellVersion {
	if config.SetupName == setupinfo.SetupNameMultiVMK8s && !config.LinuxOnly {
		return PowerShellV7
	}

	return PowerShellV5
}
