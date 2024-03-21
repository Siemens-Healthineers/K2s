// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/json"
)

type OsType string
type Nodes []NodeConfig

type Config struct {
	Host  HostConfig
	Nodes Nodes
}

type HostConfig struct {
	KubeConfigDir string
}

type NodeConfig struct {
	ShareDir string
	OsType   OsType
}

type config struct {
	SmallSetup smallSetup `json:"smallsetup"`
}

type smallSetup struct {
	ConfigDir configDir `json:"configDir"`
	ShareDir  shareDir  `json:"shareDir"`
}

type configDir struct {
	Kube string `json:"kube"`
}

type shareDir struct {
	WindowsWorker string `json:"windowsWorker"`
	Master        string `json:"master"`
}

const (
	OsTypeLinux   OsType = "linux"
	OsTypeWindows OsType = "windows"
)

func LoadConfig(installDir string) (*Config, error) {
	configFilePath := filepath.Join(installDir, "cfg\\config.json")

	config, err := json.FromFile[config](configFilePath)
	if err != nil {
		return nil, err
	}

	kubeConfigDir, err := resolveTildeInPath(config.SmallSetup.ConfigDir.Kube)
	if err != nil {
		return nil, err
	}

	return &Config{
		Host: HostConfig{
			KubeConfigDir: kubeConfigDir,
		},
		Nodes: []NodeConfig{
			{
				ShareDir: config.SmallSetup.ShareDir.WindowsWorker,
				OsType:   OsTypeWindows,
			},
			{
				ShareDir: config.SmallSetup.ShareDir.Master,
				OsType:   OsTypeLinux,
			},
		},
	}, nil
}

func resolveTildeInPath(inputPath string) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	resolvedPath := strings.ReplaceAll(inputPath, "~", homeDir)

	return filepath.Clean(resolvedPath), nil
}
