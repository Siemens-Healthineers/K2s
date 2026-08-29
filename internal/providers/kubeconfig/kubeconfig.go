// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/yaml"
)

type clusters []clusterEntry
type users []userEntry
type contexts []contextEntry

type kubeconfigRoot struct {
	Clusters       clusters `yaml:"clusters"`
	Users          users    `yaml:"users"`
	Contexts       contexts `yaml:"contexts"`
	CurrentContext string   `yaml:"current-context"`
}

type clusterEntry struct {
	Name    string         `yaml:"name"`
	Details clusterDetails `yaml:"cluster"`
}

type clusterDetails struct {
	Cert   string `yaml:"certificate-authority-data"`
	Server string `yaml:"server"`
}

type userEntry struct {
	Name    string      `yaml:"name"`
	Details userDetails `yaml:"user"`
}

type userDetails struct {
	Cert string `yaml:"client-certificate-data"`
	Key  string `yaml:"client-key-data"`
}

type contextEntry struct {
	Name    string         `yaml:"name"`
	Details contextDetails `yaml:"context"`
}

type contextDetails struct {
	Cluster string `yaml:"cluster"`
	User    string `yaml:"user"`
}

func ReadFile(path string) (*kubeconfig.Kubeconfig, error) {
	slog.Debug("Reading kubeconfig", "path", path)

	config, err := yaml.FromFile[kubeconfigRoot](path)
	if err != nil {
		return nil, fmt.Errorf("could not read kubeconfig '%s': %w", path, err)
	}
	return config.mapRoot(), nil
}

func FindCluster(config *kubeconfig.Kubeconfig, name string) (*kubeconfig.ClusterConfig, error) {
	cluster, found := lo.Find(config.Clusters, func(c kubeconfig.ClusterConfig) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("cluster '%s' not found in config", name)
	}
	return &cluster, nil
}

func FindUser(config *kubeconfig.Kubeconfig, name string) (*kubeconfig.UserConfig, error) {
	user, found := lo.Find(config.Users, func(c kubeconfig.UserConfig) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("user '%s' not found in config", name)
	}
	return &user, nil
}

func FindContextByCluster(config *kubeconfig.Kubeconfig, clusterName string) (*kubeconfig.ContextConfig, error) {
	context, found := lo.Find(config.Contexts, func(c kubeconfig.ContextConfig) bool {
		return c.Cluster == clusterName
	})
	if !found {
		return nil, fmt.Errorf("context for cluster '%s' not found in config", clusterName)
	}
	return &context, nil
}

func FindK8sApiCredentials(config *kubeconfig.Kubeconfig, contextName string) (*kubeconfig.ClusterConfig, *kubeconfig.UserConfig, error) {
	context, found := lo.Find(config.Contexts, func(c kubeconfig.ContextConfig) bool {
		return c.Name == contextName
	})
	if !found {
		return nil, nil, fmt.Errorf("context '%s' not found in config", contextName)
	}

	user, found := lo.Find(config.Users, func(u kubeconfig.UserConfig) bool {
		return u.Name == context.User
	})
	if !found {
		return nil, nil, fmt.Errorf("user '%s' not found in kubeconfig", context.User)
	}

	cluster, found := lo.Find(config.Clusters, func(c kubeconfig.ClusterConfig) bool {
		return c.Name == context.Cluster
	})
	if !found {
		return nil, nil, fmt.Errorf("cluster '%s' not found in kubeconfig", context.Cluster)
	}
	return &cluster, &user, nil
}

func (c *kubeconfigRoot) mapRoot() *kubeconfig.Kubeconfig {
	return &kubeconfig.Kubeconfig{
		CurrentContext: c.CurrentContext,
		Clusters:       c.Clusters.mapClusters(),
		Users:          c.Users.mapUsers(),
		Contexts:       c.Contexts.mapContexts(),
	}
}

func (clusters clusters) mapClusters() []kubeconfig.ClusterConfig {
	return lo.Map(clusters, func(c clusterEntry, _ int) kubeconfig.ClusterConfig {
		return kubeconfig.ClusterConfig{
			Name:   c.Name,
			Cert:   c.Details.Cert,
			Server: c.Details.Server,
		}
	})
}

func (users users) mapUsers() []kubeconfig.UserConfig {
	return lo.Map(users, func(u userEntry, _ int) kubeconfig.UserConfig {
		return kubeconfig.UserConfig{
			Name: u.Name,
			Cert: u.Details.Cert,
			Key:  u.Details.Key,
		}
	})
}

func (contexts contexts) mapContexts() []kubeconfig.ContextConfig {
	return lo.Map(contexts, func(c contextEntry, _ int) kubeconfig.ContextConfig {
		return kubeconfig.ContextConfig{
			Name:    c.Name,
			Cluster: c.Details.Cluster,
			User:    c.Details.User,
		}
	})
}
