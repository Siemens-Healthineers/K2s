// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package status

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

func LoadStatus() (*LoadedStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.InstallDir() + `\lib\scripts\k2s\status\Get-Status.ps1`)

	return powershell.ExecutePsWithStructuredResult[*LoadedStatus](scriptPath, "CmdResult", common.NewPtermWriter())
}
