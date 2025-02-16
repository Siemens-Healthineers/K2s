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

type NodesConfigReader []NodeConfigReader

type ConfigReader interface {
	Host() HostConfigReader
	Nodes() NodesConfigReader
}

type HostConfigReader interface {
	KubeConfigDir() string
	K2sConfigDir() string
	SshDir() string
}

type NodeConfigReader interface {
	ShareDir() string
	OsType() OsType
	IpAddress() string
	IsControlPlane() bool
}

type Config struct {
	HostConfig  HostConfig
	NodesConfig []NodeConfig
}

type HostConfig struct {
	KubeConfigDirectory string
	K2sConfigDirectory  string
	SshDirectory        string
}

type NodeConfig struct {
	ShareDirectory      string
	OperatingSystemType OsType
	IpAddr              string
	ControlPlane        bool
}

type configJson struct {
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

func LoadConfig(installDir string) (ConfigReader, error) {
	configFilePath := filepath.Join(installDir, "cfg\\config.json")

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error occurred while loading config file: %w", err)
	}

	kubeConfigDir, err := host.ResolveTildePrefix(configJson.ConfigDir.Kube)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Kube, err)
	}

	sshDir, err := host.ResolveTildePrefix(configJson.ConfigDir.Ssh)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Ssh, err)
	}

	return &Config{
		HostConfig: HostConfig{
			KubeConfigDirectory: kubeConfigDir,
			K2sConfigDirectory:  configJson.ConfigDir.K2s,
			SshDirectory:        sshDir,
		},
		NodesConfig: []NodeConfig{
			{
				ShareDirectory:      configJson.SmallSetup.ShareDir.WindowsWorker,
				OperatingSystemType: OsTypeWindows,
				IpAddr:              configJson.SmallSetup.Multivm.IpAddress,
			},
			{
				ShareDirectory:      configJson.SmallSetup.ShareDir.Master,
				OperatingSystemType: OsTypeLinux,
				IpAddr:              configJson.SmallSetup.ControlPlanIpAddress,
				ControlPlane:        true,
			},
		},
	}, nil
}

func (c *Config) Host() HostConfigReader {
	return c.HostConfig
}

func (c *Config) Nodes() NodesConfigReader {
	nodes := make([]NodeConfigReader, len(c.NodesConfig))
	for i, node := range c.NodesConfig {
		nodes[i] = node
	}
	return nodes
}

func (c HostConfig) KubeConfigDir() string {
	return c.KubeConfigDirectory
}

func (c HostConfig) K2sConfigDir() string {
	return c.K2sConfigDirectory
}

func (c HostConfig) SshDir() string {
	return c.SshDirectory
}

func (c NodeConfig) ShareDir() string {
	return c.ShareDirectory
}

func (c NodeConfig) OsType() OsType {
	return c.OperatingSystemType
}

func (c NodeConfig) IpAddress() string {
	return c.IpAddr
}

func (c NodeConfig) IsControlPlane() bool {
	return c.ControlPlane
}
