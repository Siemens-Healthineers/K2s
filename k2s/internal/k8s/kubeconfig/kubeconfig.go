// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/yaml"
)

type KubeconfigRoot struct {
	Clusters       []ClusterEntry `yaml:"clusters"`
	Users          []UserEntry    `yaml:"users"`
	Contexts       []ContextEntry `yaml:"contexts"`
	CurrentContext string         `yaml:"current-context"`
}

type ClusterEntry struct {
	Name    string         `yaml:"name"`
	Details ClusterDetails `yaml:"cluster"`
}

type ClusterDetails struct {
	Cert   string `yaml:"certificate-authority-data"`
	Server string `yaml:"server"`
}

type UserEntry struct {
	Name    string      `yaml:"name"`
	Details UserDetails `yaml:"user"`
}

type UserDetails struct {
	Cert string `yaml:"client-certificate-data"`
	Key  string `yaml:"client-key-data"`
}

type ContextEntry struct {
	Name    string         `yaml:"name"`
	Details ContextDetails `yaml:"context"`
}

type ContextDetails struct {
	Cluster string `yaml:"cluster"`
}

func ReadFile(path string) (*KubeconfigRoot, error) {
	slog.Debug("Reading kubeconfig", "path", path)

	config, err := yaml.FromFile[KubeconfigRoot](path)
	if err != nil {
		return nil, fmt.Errorf("could not read kubeconfig '%s': %w", path, err)
	}
	return config, nil
}

func (root *KubeconfigRoot) FindCluster(name string) (*ClusterEntry, error) {
	cluster, found := lo.Find(root.Clusters, func(c ClusterEntry) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("cluster '%s' not found in config", name)
	}
	return &cluster, nil
}

func (root *KubeconfigRoot) FindUser(name string) (*UserEntry, error) {
	user, found := lo.Find(root.Users, func(c UserEntry) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("user '%s' not found in config", name)
	}
	return &user, nil
}

func (root *KubeconfigRoot) FindContextByCluster(clusterName string) (*ContextEntry, error) {
	context, found := lo.Find(root.Contexts, func(c ContextEntry) bool {
		return c.Details.Cluster == clusterName
	})
	if !found {
		return nil, fmt.Errorf("context for cluster '%s' not found in config", clusterName)
	}
	return &context, nil
}
