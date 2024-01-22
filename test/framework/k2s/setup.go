// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type SetupInfo struct {
	SetupType                SetupType
	WinNodeName              string
	ControlPlaneNodeHostname string
	SmbShareDir              string
	Registries               []string
}

type SetupType struct {
	Name      string
	LinuxOnly bool
}

type config struct {
	SmallSetup smallSetupConfig `json:"smallsetup"`
}

type smallSetupConfig struct {
	ConfigDir configDir `json:"configDir"`
	ShareDir  shareDir  `json:"shareDir"`
}

type configDir struct {
	Kube string `json:"kube"`
}

type shareDir struct {
	WorkerNode string `json:"windowsWorker"`
}

type setupConfig struct {
	SetupType                string   `json:"SetupType"`
	ControlPlaneNodeHostname string   `json:"ControlPlaneNodeHostname"`
	LinuxOnly                bool     `json:"LinuxOnly"`
	Registries               []string `json:"Registries"`
}

func GetSetupInfo(rootDir string) (*SetupInfo, error) {
	configPath := filepath.Join(rootDir, "cfg", "config.json")

	binaries, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	var config config
	err = json.Unmarshal(binaries, &config)
	if err != nil {
		return nil, err
	}

	setupConfigPath, err := buildSetupConfigPath(config.SmallSetup.ConfigDir.Kube, "setup.json")
	if err != nil {
		return nil, err
	}

	binaries, err = os.ReadFile(setupConfigPath)
	if err != nil {
		return nil, err
	}

	var setupConfig setupConfig
	err = json.Unmarshal(binaries, &setupConfig)
	if err != nil {
		return nil, err
	}

	winNodeName, err := getWinNodeName(setupConfig.SetupType)
	if err != nil {
		return nil, err
	}

	return &SetupInfo{
		SetupType: SetupType{
			Name:      setupConfig.SetupType,
			LinuxOnly: setupConfig.LinuxOnly,
		},
		WinNodeName:              winNodeName,
		ControlPlaneNodeHostname: setupConfig.ControlPlaneNodeHostname,
		SmbShareDir:              config.SmallSetup.ShareDir.WorkerNode,
		Registries:               setupConfig.Registries,
	}, nil
}

func getWinNodeName(setupType string) (string, error) {
	switch setupType {
	case "k2s":
		name, err := os.Hostname()
		if err != nil {
			return "", err
		}
		return strings.ToLower(name), nil
	case "MultiVMK8s":
		return "winnode", nil
	default:
		return "", errors.New("no setup type defined")
	}
}

func buildSetupConfigPath(configDir string, configFileName string) (string, error) {
	if strings.HasPrefix(configDir, "~/") {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}

		configDir = filepath.Join(homeDir, configDir[2:])
	}

	result := filepath.Join(configDir, configFileName)

	return result, nil
}
