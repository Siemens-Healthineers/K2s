// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
)

type SetupName string
type SetupError string

type SetupInfo struct {
	Version   string    `json:"version"`
	Name      SetupName `json:"name"`
	LinuxOnly bool      `json:"linuxOnly"`
}

const (
	SetupNamek2s          SetupName = "k2s"
	SetupNameMultiVMK8s   SetupName = "MultiVMK8s"
	SetupNameBuildOnlyEnv SetupName = "BuildOnlyEnv"
)

var (
	ErrSystemNotInstalled = errors.New("system-not-installed")
)
