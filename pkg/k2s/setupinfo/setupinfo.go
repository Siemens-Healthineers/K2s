// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import "errors"

type SetupError string
type SetupName string

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

	ErrNotInstalledMsg SetupError = "not-installed"
	ErrNotRunningMsg   SetupError = "not-running"
)

var ErrNotInstalled = errors.New(string(ErrNotInstalledMsg))
