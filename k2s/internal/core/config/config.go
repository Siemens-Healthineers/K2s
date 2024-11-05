// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"fmt"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type OsType string
type Nodes []NodeConfig

// TODO: immutable read objects
type Config struct {
	Host  HostConfig
	Nodes Nodes
}

type HostConfig struct {
	KubeConfigDir string
	K2sConfigDir  string
	SshDir        string
}

type NodeConfig struct {
	ShareDir       string
	OsType         OsType
	IpAddress      string
	IsControlPlane bool
}

type config struct {
	SmallSetup smallSetup `json:"smallsetup"`
	ConfigDir  configDir  `json:"configDir"`
}

type smallSetup struct {
	ShareDir             shareDir `json:"shareDir"`
	ControlPlanIpAddress string   `json:"masterIP"`
	Multivm              multivm  `json:"multivm"`
}

type configDir struct {
	Kube string `json:"kube"`
	K2s  string `json:"k2s"`
	Ssh  string `json:"ssh"`
}

type shareDir struct {
	WindowsWorker string `json:"windowsWorker"`
	Master        string `json:"master"`
}

type multivm struct {
	IpAddress string `json:"multiVMK8sWindowsVMIP"`
}

const (
	OsTypeLinux   OsType = "linux"
	OsTypeWindows OsType = "windows"
)

func LoadConfig(installDir string) (*Config, error) {
	configFilePath := filepath.Join(installDir, "cfg\\config.json")

	config, err := json.FromFile[config](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error occurred while loading config file: %w", err)
	}

	kubeConfigDir, err := host.ReplaceTildeWithHomeDir(config.ConfigDir.Kube)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", config.ConfigDir.Kube, err)
	}

	sshDir, err := host.ReplaceTildeWithHomeDir(config.ConfigDir.Ssh)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", config.ConfigDir.Ssh, err)
	}

	return &Config{
		Host: HostConfig{
			KubeConfigDir: kubeConfigDir,
			K2sConfigDir:  config.ConfigDir.K2s,
			SshDir:        sshDir,
		},
		Nodes: []NodeConfig{
			{
				ShareDir:  config.SmallSetup.ShareDir.WindowsWorker,
				OsType:    OsTypeWindows,
				IpAddress: config.SmallSetup.Multivm.IpAddress,
			},
			{
				ShareDir:       config.SmallSetup.ShareDir.Master,
				OsType:         OsTypeLinux,
				IpAddress:      config.SmallSetup.ControlPlanIpAddress,
				IsControlPlane: true,
			},
		},
	}, nil
}
