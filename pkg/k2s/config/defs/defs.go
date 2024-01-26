// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package defs

import (
	"k2s/setupinfo"
)

type SmbHostType string
type RegistryName string

type SetupConfig struct {
	SetupName        setupinfo.SetupName `json:"SetupType"`
	Registries       []RegistryName      `json:"Registries"`
	LoggedInRegistry string              `json:"LoggedInRegistry"`
	LinuxOnly        bool                `json:"LinuxOnly"`
}

type Config struct {
	SmallSetup SmallSetupConfig `json:"smallsetup"`
}

type SmallSetupConfig struct {
	ConfigDir ConfigDir `json:"configDir"`
}

type ConfigDir struct {
	Kube string `json:"kube"`
}

type KubeConfig struct {
	Clusters       []KubeCluster `yaml:"clusters"`
	Contexts       []KubeContext `yaml:"contexts"`
	CurrentContext string        `yaml:"current-context"`
	Users          []KubeUser    `yaml:"users"`
}

type KubeCluster struct {
	Name        string          `yaml:"name"`
	ClusterData KubeClusterData `yaml:"cluster"`
}

type KubeContext struct {
	Name        string          `yaml:"name"`
	ContextData KubeContextData `yaml:"context"`
}
type KubeUser struct {
	Name     string       `yaml:"name"`
	UserData KubeUserData `yaml:"user"`
}

type KubeClusterData struct {
	Server string `yaml:"server"`
}

type KubeContextData struct {
	Cluster   string `yaml:"cluster"`
	Namespace string `yaml:"namespace"`
	User      string `yaml:"user"`
}

type KubeUserData struct {
	ClientCertData string `yaml:"client-certificate-data"`
	ClientKeyData  string `yaml:"client-key-data"`
}

const (
	SmbHostTypeLinux   SmbHostType = "Linux"
	SmbHostTypeWindows SmbHostType = "Windows"
	SmbHostTypeAuto    SmbHostType = "Auto"
)
