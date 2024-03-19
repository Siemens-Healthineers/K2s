// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/json"
)

type config struct {
	SmallSetup smallSetupConfig `json:"smallsetup"`
}

type smallSetupConfig struct {
	ConfigDir configDir `json:"configDir"`
}

type configDir struct {
	Kube string `json:"kube"`
}

func LoadSetupConfigDir(installDir string) (string, error) {
	configFilePath := filepath.Join(installDir, "cfg\\config.json")

	config, err := json.FromFile[config](configFilePath)
	if err != nil {
		return "", err
	}

	dir, err := resolveTildeInPath(config.SmallSetup.ConfigDir.Kube)
	if err != nil {
		return "", err
	}

	return dir, nil
}

func resolveTildeInPath(inputPath string) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return strings.ReplaceAll(inputPath, "~", homeDir), nil
}
