// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"fmt"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type ConfigReader interface {
	Host() HostConfigReader
	ControlPlane() ControlPlaneConfigReader
}

type HostConfigReader interface {
	KubeConfigDir() string
	K2sConfigDir() string
	SshDir() string
}

type ControlPlaneConfigReader interface {
	IpAddress() string
}

type Config struct {
	HostConfig         HostConfig
	ControlPlaneConfig ControlPlaneConfig
}

type HostConfig struct {
	KubeConfigDirectory string
	K2sConfigDirectory  string
	SshDirectory        string
}

type ControlPlaneConfig struct {
	IpAddr string
}

type configJson struct {
	SmallSetup smallSetup `json:"smallsetup"`
	ConfigDir  configDir  `json:"configDir"`
}

type smallSetup struct {
	ControlPlanIpAddress string `json:"masterIP"`
}

type configDir struct {
	Kube string `json:"kube"`
	K2s  string `json:"k2s"`
	Ssh  string `json:"ssh"`
}

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
		ControlPlaneConfig: ControlPlaneConfig{
			IpAddr: configJson.SmallSetup.ControlPlanIpAddress,
		},
	}, nil
}

func (c *Config) Host() HostConfigReader {
	return c.HostConfig
}

func (c *Config) ControlPlane() ControlPlaneConfigReader {
	return c.ControlPlaneConfig
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

func (c ControlPlaneConfig) IpAddress() string {
	return c.IpAddr
}
