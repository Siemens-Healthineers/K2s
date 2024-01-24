// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"k2s/utils"
)

type AddonStatus struct {
	Name    string            `json:"name"`
	Error   *string           `json:"error"`
	Enabled *bool             `json:"enabled"`
	Props   []AddonStatusProp `json:"props"`
}

type AddonStatusProp struct {
	Value   any     `json:"value"`
	Okay    *bool   `json:"okay"`
	Message *string `json:"message"`
	Name    string  `json:"name"`
}

func LoadAddonStatus(addonName string, addonDirectory string) (*AddonStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Get-Status.ps1")

	status, err := utils.LoadStructure[*AddonStatus](scriptPath, "Status", utils.ExecOptions{IgnoreNotInstalledErr: true}, "-Name", addonName, "-Directory", utils.EscapeWithSingleQuotes(addonDirectory))
	if err != nil {
		return nil, err
	}

	return status, nil
}
