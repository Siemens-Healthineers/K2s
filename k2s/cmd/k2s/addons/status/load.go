// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/setupinfo"

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

func LoadAddonStatus(addonName string, addonDirectory string) (*LoadedAddonStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Get-Status.ps1")

	status, err := psexecutor.ExecutePsWithStructuredResult[*LoadedAddonStatus](scriptPath, "Status", psexecutor.ExecOptions{}, "-Name", addonName, "-Directory", utils.EscapeWithSingleQuotes(addonDirectory))
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return nil, err
		}
		status = &LoadedAddonStatus{CmdResult: common.CreateSystemNotInstalledCmdResult()}
	}

	return status, nil
}
