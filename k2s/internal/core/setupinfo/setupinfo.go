// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
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
	ClusterName              string    `json:"ClusterName"`
}

const (
	SetupNamek2s          SetupName = "k2s"
	SetupNameBuildOnlyEnv SetupName = "BuildOnlyEnv"

	ConfigFileName = "setup.json"

	corruptedKey      = "Corrupted"
	legacyClusterName = "kubernetes"
)

var (
	ErrSystemNotInstalled     = errors.New("system-not-installed")
	ErrSystemInCorruptedState = errors.New("system-in-corrupted-state")
)

func ReadConfig(configDir string) (*Config, error) {
	configPath := filepath.Join(configDir, ConfigFileName)

	config, err := json.FromFile[Config](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Debug("Setup config file not found, assuming setup is not installed", "err-msg", err, "path", configPath)

			return nil, ErrSystemNotInstalled
		}
		return nil, fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	if config.Corrupted {
		// <config> instead of <nil> so that e.g. 'k2s uninstall' cmd can use it's content
		return config, ErrSystemInCorruptedState
	}

	if config.ClusterName == "" {
		slog.Info("Cluster name not found in setup config, defaulting to legacy cluster name", "cluster-name", legacyClusterName)
		config.ClusterName = legacyClusterName
	}

	return config, nil
}

func MarkSetupAsCorrupted(configDir string) error {
	configPath := filepath.Join(configDir, ConfigFileName)

	config, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			newConfig := map[string]any{corruptedKey: true}

			return json.ToFile(configPath, &newConfig)
		}
		return fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	(*config)[corruptedKey] = true

	return json.ToFile(configPath, config)
}
