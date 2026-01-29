// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	contracts "github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/providers/kubeconfig"
)

type ClusterFinder struct {
	clusterName string
}

type CredentialsFinder struct{}

func NewClusterFinder(config *config.K2sClusterConfig) *ClusterFinder {
	return &ClusterFinder{
		clusterName: config.Name(),
	}
}

func NewCredentialsFinder() *CredentialsFinder {
	return &CredentialsFinder{}
}

func (c *ClusterFinder) FindK2sCluster(config *contracts.Kubeconfig) (*contracts.ClusterConfig, error) {
	return kubeconfig.FindCluster(config, c.clusterName)
}

func (c *CredentialsFinder) FindK8sApiCredentials(config *contracts.Kubeconfig, contextName string) (*contracts.ClusterConfig, *contracts.UserConfig, error) {
	return kubeconfig.FindK8sApiCredentials(config, contextName)
}
