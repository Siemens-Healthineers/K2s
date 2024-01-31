// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"k2s/setupinfo"
	"k2s/status"
	"k2s/utils"
)

type AddonError string

type AddonLoadStatus struct {
	Error   *AddonError       `json:"error"`
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
	errAddonNotFoundMsg AddonError = "addon-not-found"
	errNoAddonStatusMsg AddonError = "no-addon-status"
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
		return nil, status.Error.ToError()
	}

	return status, nil
}

func (err AddonError) ToError() error {
	if status.IsErrNotRunning(string(err)) {
		return status.ErrNotRunning
	}
	if setupinfo.IsErrNotInstalled(string(err)) {
		return setupinfo.ErrNotInstalled
	}

	switch err {
	case errAddonNotFoundMsg:
		return ErrAddonNotFound
	case errNoAddonStatusMsg:
		return ErrNoAddonStatus
	default:
		return errors.New(string(err))
	}
}
