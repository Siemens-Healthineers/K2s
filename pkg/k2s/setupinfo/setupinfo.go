// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
)

type SetupName string
type SetupError string

type SetupInfo struct {
	Version   *string     `json:"version"`
	Name      *SetupName  `json:"name"`
	Error     *SetupError `json:"validationError"`
	LinuxOnly *bool       `json:"linuxOnly"`
}

const (
	SetupNamek2s          SetupName = "k2s"
	SetupNameMultiVMK8s   SetupName = "MultiVMK8s"
	SetupNameBuildOnlyEnv SetupName = "BuildOnlyEnv"

	ErrNotInstalledMsg SetupError = "system-not-installed"
)

var (
	ErrNotInstalled = errors.New(string(ErrNotInstalledMsg))
)

func (err SetupError) ToError() error {
	if err == ErrNotInstalledMsg {
		return ErrNotInstalled
	}

	return errors.New(string(err))
}

func IsErrNotInstalled(err string) bool {
	return err == string(ErrNotInstalledMsg)
}
