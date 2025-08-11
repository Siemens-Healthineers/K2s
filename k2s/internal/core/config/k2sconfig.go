// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"fmt"
	"path/filepath"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/json"
)

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

func ReadK2sConfig(k2sInstallDir string) (*cconfig.K2sConfig, error) {
	configFilePath := filepath.Join(k2sInstallDir, "cfg\\config.json")

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error occurred while loading config file: %w", err)
	}

	kubeConfigDir, err := host.ResolveTildePrefixForCurrentUser(configJson.ConfigDir.Kube)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Kube, err)
	}

	sshDir, err := host.ResolveTildePrefixForCurrentUser(configJson.ConfigDir.Ssh)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Ssh, err)
	}

	kubeConfig := cconfig.NewKubeConfig(kubeConfigDir, configJson.ConfigDir.Kube, filepath.Join(kubeConfigDir, definitions.KubeconfigName))
	sshConfig := cconfig.NewSshConfig(sshDir, configJson.ConfigDir.Ssh, filepath.Join(sshDir, definitions.SSHSubDirName, definitions.SSHPrivateKeyName))
	hostConfig := cconfig.NewHostConfig(kubeConfig, sshConfig, configJson.ConfigDir.K2s, k2sInstallDir)
	controlPlaneConfig := cconfig.NewControlPlaneConfig(configJson.SmallSetup.ControlPlanIpAddress)

	return cconfig.NewK2sConfig(hostConfig, controlPlaneConfig), nil
}
