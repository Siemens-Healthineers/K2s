// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
)

type LoadedAddonStatus struct {
	common.CmdResult
	Enabled *bool             `json:"enabled"`
	Props   []AddonStatusProp `json:"props"`
}

type AddonStatusProp struct {
	Value   any     `json:"value"`
	Okay    *bool   `json:"okay"`
	Message *string `json:"message"`
	Name    string  `json:"name"`
}

func LoadAddonStatus(addonName string, addonDirectory string, psVersion powershell.PowerShellVersion) (*LoadedAddonStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.InstallDir() + "\\addons\\Get-Status.ps1")

	return powershell.ExecutePsWithStructuredResult[*LoadedAddonStatus](
		scriptPath,
		"Status",
		psVersion,
		common.NewOutputWriter(),
		"-Name",
		addonName,
		"-Directory",
		utils.EscapeWithSingleQuotes(addonDirectory))
}
