// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
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
	LinuxOnly                bool      `json:"LinuxOnly"`
	Version                  string    `json:"Version"`
	ControlPlaneNodeHostname string    `json:"ControlPlaneNodeHostname"`
	Corrupted                bool      `json:"Corrupted"`
}

const (
	SetupNamek2s          SetupName = "k2s"
	SetupNameMultiVMK8s   SetupName = "MultiVMK8s"
	SetupNameBuildOnlyEnv SetupName = "BuildOnlyEnv"

	ConfigFileName = "setup.json"
)

var (
	ErrSystemNotInstalled     = errors.New("system-not-installed")
	ErrSystemInCorruptedState = errors.New("system-in-corrupted-state")
)

// TODO: basically not necessary since dir and file name are known to caller
func ConfigPath(configDir string) string {
	return filepath.Join(configDir, ConfigFileName)
}

func ReadConfig(configDir string) (*Config, error) {
	configPath := ConfigPath(configDir)

	config, err := json.FromFile[Config](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Info("Setup config file not found, assuming setup is not installed", "err-msg", err, "path", configPath)

			return nil, ErrSystemNotInstalled
		}
		return nil, fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	if config.Corrupted {
		return config, ErrSystemInCorruptedState
	}

	return config, nil
}

func WriteConfig(configDir string, config *Config) error {
	configPath := ConfigPath(configDir)

	return json.ToFile(configPath, config)
}

func DeleteConfig(configDir string) error {
	configPath := ConfigPath(configDir)

	return os.Remove(configPath)
}
