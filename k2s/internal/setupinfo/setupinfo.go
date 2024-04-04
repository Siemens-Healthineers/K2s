// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/json"
)

type SetupName string

type Config struct {
	SetupName                SetupName `json:"SetupType"`
	Registries               []string  `json:"Registries"`
	LoggedInRegistry         string    `json:"LoggedInRegistry"`
	LinuxOnly                bool      `json:"LinuxOnly"`
	Version                  string    `json:"Version"`
	ControlPlaneNodeHostname string    `json:"ControlPlaneNodeHostname"`
}

const (
	SetupNamek2s          SetupName = "k2s"
	SetupNameMultiVMK8s   SetupName = "MultiVMK8s"
	SetupNameBuildOnlyEnv SetupName = "BuildOnlyEnv"
)

var (
	ErrSystemNotInstalled = errors.New("system-not-installed")
)

func LoadConfig(configDir string) (*Config, error) {
	configPath := filepath.Join(configDir, "setup.json")

	config, err := json.FromFile[Config](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Info("Setup config file not found, assuming setup is not installed", "error", err, "path", configPath)

			return nil, ErrSystemNotInstalled
		}
		return nil, fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	return config, nil
}
