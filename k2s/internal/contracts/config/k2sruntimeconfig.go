// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"errors"
)

type Registry string

type K2sRuntimeConfig struct {
	clusterConfig      *K2sClusterConfig
	installConfig      *K2sInstallConfig
	controlPlaneConfig *K2sControlPlaneConfig
}

type K2sClusterConfig struct {
	name               string
	registries         []Registry
	controlPlaneConfig *K2sControlPlaneConfig
}

type K2sInstallConfig struct {
	setupName string
	linuxonly bool
	version   string
	corrupted bool
}

type K2sControlPlaneConfig struct {
	hostname string
}

var (
	ErrSystemNotInstalled     = errors.New("system-not-installed")
	ErrSystemInCorruptedState = errors.New("system-in-corrupted-state")
)

func NewK2sRuntimeConfig(clusterConfig *K2sClusterConfig, installConfig *K2sInstallConfig, controlPlaneConfig *K2sControlPlaneConfig) *K2sRuntimeConfig {
	return &K2sRuntimeConfig{
		clusterConfig:      clusterConfig,
		installConfig:      installConfig,
		controlPlaneConfig: controlPlaneConfig,
	}
}

func NewK2sClusterConfig(name string, registries []Registry, controlPlaneConfig *K2sControlPlaneConfig) *K2sClusterConfig {
	return &K2sClusterConfig{
		name:               name,
		registries:         registries,
		controlPlaneConfig: controlPlaneConfig,
	}
}

func NewK2sInstallConfig(setupName string, linuxonly bool, version string, corrupted bool) *K2sInstallConfig {
	return &K2sInstallConfig{
		setupName: setupName,
		linuxonly: linuxonly,
		version:   version,
		corrupted: corrupted,
	}
}

func NewK2sControlPlaneConfig(hostname string) *K2sControlPlaneConfig {
	return &K2sControlPlaneConfig{
		hostname: hostname,
	}
}

func (c *K2sRuntimeConfig) ClusterConfig() *K2sClusterConfig {
	return c.clusterConfig
}

func (c *K2sRuntimeConfig) InstallConfig() *K2sInstallConfig {
	return c.installConfig
}

func (c *K2sRuntimeConfig) ControlPlaneConfig() *K2sControlPlaneConfig {
	return c.controlPlaneConfig
}

func (c *K2sClusterConfig) Name() string {
	return c.name
}

func (c *K2sClusterConfig) Registries() []Registry {
	return c.registries
}

func (c *K2sClusterConfig) ControlPlaneConfig() *K2sControlPlaneConfig {
	return c.controlPlaneConfig
}

func (c *K2sInstallConfig) SetupName() string {
	return c.setupName
}

func (c *K2sInstallConfig) LinuxOnly() bool {
	return c.linuxonly
}

func (c *K2sInstallConfig) Version() string {
	return c.version
}

func (c *K2sInstallConfig) Corrupted() bool {
	return c.corrupted
}

func (c *K2sControlPlaneConfig) Hostname() string {
	return c.hostname
}
