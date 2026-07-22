// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"fmt"
	"net"
	"path/filepath"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/json"
)

type cloudImageConfig struct {
	UrlRoot string `json:"urlRoot"`
	UrlFile string `json:"urlFile"`
}

type supportedWorkerOSEntry struct {
	OS         string           `json:"os"`
	CloudImage cloudImageConfig `json:"cloudImage"`
}

type configJson struct {
	SmallSetup        smallSetup               `json:"smallsetup"`
	ConfigDir         configDir                `json:"configDir"`
	SupportedWorkerOS []supportedWorkerOSEntry `json:"supportedWorkerOS"`
}

type smallSetup struct {
	ControlPlanIpAddress string `json:"masterIP"`
	MasterNetworkCIDR    string `json:"masterNetworkCIDR"`
}

type configDir struct {
	Kube string `json:"kube"`
	K2s  string `json:"k2s"`
	Ssh  string `json:"ssh"`
	Logs string `json:"logs"`
}

// configFileRelDir and configFileName are joined via filepath.Join so the
// correct OS path separator is used on both Windows and Linux.
const (
	configFileRelDir = "cfg"
	configFileName   = "config.json"
)

func ReadK2sConfig(k2sInstallDir string) (*cconfig.K2sConfig, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

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
	hostConfig := cconfig.NewHostConfig(kubeConfig, sshConfig, configJson.ConfigDir.K2s, k2sInstallDir, configJson.ConfigDir.Logs)
	controlPlaneConfig := cconfig.NewControlPlaneConfig(configJson.SmallSetup.ControlPlanIpAddress)

	return cconfig.NewK2sConfig(hostConfig, controlPlaneConfig), nil
}

// ReadSupportedWorkerOS returns the list of supported worker OS keys (e.g. "debian12", "debian13")
// from the supportedWorkerOS array in cfg/config.json.
func ReadSupportedWorkerOS(k2sInstallDir string) ([]string, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}

	result := make([]string, 0, len(configJson.SupportedWorkerOS))
	for _, entry := range configJson.SupportedWorkerOS {
		result = append(result, entry.OS)
	}
	return result, nil
}

func ReadKubeSwitchCIDR(k2sInstallDir string) (string, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return "", fmt.Errorf("error reading config file: %w", err)
	}

	return configJson.SmallSetup.MasterNetworkCIDR, nil
}

func DetectLocalVM(ipAddress, installDir string) (bool, error) {
	cidr, err := ReadKubeSwitchCIDR(installDir)
	if err != nil {
		return false, fmt.Errorf("cannot read KubeSwitch CIDR: %w", err)
	}
	if cidr == "" {
		return false, nil
	}
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return false, fmt.Errorf("invalid KubeSwitch CIDR '%s': %w", cidr, err)
	}
	ip := net.ParseIP(ipAddress)
	if ip == nil {
		return false, nil
	}
	return network.Contains(ip), nil
}
