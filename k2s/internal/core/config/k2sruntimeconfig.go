// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type config struct {
	SetupName                string             `json:"SetupType"`
	Registries               []cconfig.Registry `json:"Registries"`
	LinuxOnly                bool               `json:"LinuxOnly"`
	Version                  string             `json:"Version"`
	ControlPlaneNodeHostname string             `json:"ControlPlaneNodeHostname"`
	Corrupted                bool               `json:"Corrupted"`
	ClusterName              string             `json:"ClusterName"`
}

func ReadRuntimeConfig(configDir string) (*cconfig.K2sRuntimeConfig, error) {
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	config, err := json.FromFile[config](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Debug("Setup config file not found, assuming setup is not installed", "err-msg", err, "path", configPath)

			return nil, cconfig.ErrSystemNotInstalled
		}
		return nil, fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	if config.ClusterName == "" {
		slog.Info("Cluster name not found in setup config, defaulting to legacy cluster name", "cluster-name", definitions.LegacyClusterName)
		config.ClusterName = definitions.LegacyClusterName
	}

	controlPlaneConfig := cconfig.NewK2sControlPlaneConfig(config.ControlPlaneNodeHostname)
	clusterConfig := cconfig.NewK2sClusterConfig(config.ClusterName, config.Registries, controlPlaneConfig)
	installConfig := cconfig.NewK2sInstallConfig(config.SetupName, config.LinuxOnly, config.Version, config.Corrupted)
	k2sRuntimeConfig := cconfig.NewK2sRuntimeConfig(clusterConfig, installConfig, controlPlaneConfig)

	if config.Corrupted {
		// <config> instead of <nil> so that e.g. 'k2s uninstall' cmd can use it's content
		return k2sRuntimeConfig, cconfig.ErrSystemInCorruptedState
	}
	return k2sRuntimeConfig, nil
}

func MarkSetupAsCorrupted(configDir string) error {
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	config, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			newConfig := map[string]any{definitions.SetupCorruptedKey: true}

			return json.ToFile(configPath, &newConfig)
		}
		return fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	(*config)[definitions.SetupCorruptedKey] = true

	return json.ToFile(configPath, config)
}
