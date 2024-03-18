// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package defs

import (
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type RegistryName string

type SetupConfig struct {
	SetupName        setupinfo.SetupName `json:"SetupType"`
	Registries       []RegistryName      `json:"Registries"`
	LoggedInRegistry string              `json:"LoggedInRegistry"`
	LinuxOnly        bool                `json:"LinuxOnly"`
}

type Config struct {
	SmallSetup SmallSetupConfig `json:"smallsetup"`
}

type SmallSetupConfig struct {
	ConfigDir ConfigDir `json:"configDir"`
}

type ConfigDir struct {
	Kube string `json:"kube"`
}
