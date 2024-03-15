// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	d "github.com/siemens-healthineers/k2s/cmd/k2s/config/defs"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type ConfigLoader interface {
	Load(filePath string) (*d.Config, error)
	LoadForSetup(filePath string) (*d.SetupConfig, error)
}

type SetupConfigPathBuilder interface {
	Build(configDir string, configFileName string) (string, error)
}

type ConfigAccess struct {
	configLoader ConfigLoader
	pathBuilder  SetupConfigPathBuilder
	setupConfig  *d.SetupConfig
}

const (
	setupConfigFileName = "setup.json"
	kubeConfigFileName  = "config"
)

var (
	SetupRootDir   = utils.GetInstallationDirectory()
	smallSetupDir  = SetupRootDir + "\\smallsetup"
	configFilePath = SetupRootDir + "\\cfg\\config.json"
)

func NewConfigAccess(configLoader ConfigLoader, pathBuilder SetupConfigPathBuilder) *ConfigAccess {
	return &ConfigAccess{
		configLoader: configLoader,
		pathBuilder:  pathBuilder,
	}
}

func SmallSetupDir() string {
	return smallSetupDir
}

func (c *ConfigAccess) SmallSetupDir() string {
	return SmallSetupDir()
}

func (c *ConfigAccess) GetSetupName() (setupinfo.SetupName, error) {
	if c.setupConfig != nil {
		return setupinfo.SetupName(c.setupConfig.SetupName), nil
	}

	config, err := c.loadSetupConfig()
	if err != nil {
		return "", err
	}

	c.setupConfig = config

	return setupinfo.SetupName(config.SetupName), nil
}

func (c *ConfigAccess) IsLinuxOnly() (bool, error) {
	if c.setupConfig != nil {
		return c.setupConfig.LinuxOnly, nil
	}

	config, err := c.loadSetupConfig()
	if err != nil {
		return false, err
	}

	c.setupConfig = config

	return c.setupConfig.LinuxOnly, nil
}

func (c *ConfigAccess) GetConfiguredRegistries() ([]d.RegistryName, error) {
	if c.setupConfig != nil {
		return c.setupConfig.Registries, nil
	}

	config, err := c.loadSetupConfig()
	if err != nil {
		return nil, err
	}

	c.setupConfig = config

	return c.setupConfig.Registries, nil
}

func (c *ConfigAccess) GetLoggedInRegistry() (string, error) {
	if c.setupConfig != nil {
		return c.setupConfig.LoggedInRegistry, nil
	}

	config, err := c.loadSetupConfig()
	if err != nil {
		return "", err
	}

	c.setupConfig = config

	return c.setupConfig.LoggedInRegistry, nil
}

func (c *ConfigAccess) loadSetupConfig() (*d.SetupConfig, error) {
	config, err := c.configLoader.Load(configFilePath)
	if err != nil {
		return nil, err
	}

	setupConfigPath, err := c.pathBuilder.Build(config.SmallSetup.ConfigDir.Kube, setupConfigFileName)
	if err != nil {
		return nil, err
	}

	return c.configLoader.LoadForSetup(setupConfigPath)
}
