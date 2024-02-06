// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"k2s/cmd/common"
	"k2s/utils"
)

type AddonLoadStatus struct {
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

const (
	errAddonNotFoundMsg common.CmdError = "addon-not-found"
	errNoAddonStatusMsg common.CmdError = "no-addon-status"
)

var (
	ErrAddonNotFound = errors.New(string(errAddonNotFoundMsg))
	ErrNoAddonStatus = errors.New(string(errNoAddonStatusMsg))
)

func LoadAddonStatus(addonName string, addonDirectory string) (*AddonLoadStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Get-Status.ps1")

	status, err := utils.ExecutePsWithStructuredResult[*AddonLoadStatus](scriptPath, "Status", utils.ExecOptions{}, "-Name", addonName, "-Directory", utils.EscapeWithSingleQuotes(addonDirectory))
	if err != nil {
		return nil, err
	}

	if status.Error != nil {
		return nil, toError(*status.Error)
	}

	return status, nil
}

func toError(err common.CmdError) error {
	switch err {
	case errAddonNotFoundMsg:
		return ErrAddonNotFound
	case errNoAddonStatusMsg:
		return ErrNoAddonStatus
	default:
		return err.ToError()
	}
}
