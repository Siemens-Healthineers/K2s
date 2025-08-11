// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package k8s

import (
	"fmt"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/providers/kubeconfig"
)

type K8sContext struct {
	currentContext string
	k2sContext     string
}

const KubeconfigName = "config"

func ReadContext(kubeconfigDir string, clusterName string) (*K8sContext, error) {
	path := filepath.Join(kubeconfigDir, KubeconfigName)

	config, err := kubeconfig.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read kubeconfig from dir '%s': %w", kubeconfigDir, err)
	}

	k2sContext, err := kubeconfig.FindContextByCluster(config, clusterName)
	if err != nil {
		return nil, fmt.Errorf("could not find K2s cluster config in kubeconfig: %w", err)
	}

	return &K8sContext{
		currentContext: config.CurrentContext,
		k2sContext:     k2sContext.Name,
	}, nil
}

func (c *K8sContext) IsK2sContext() bool {
	return c.currentContext == c.k2sContext
}

func (c *K8sContext) K2sContextName() string {
	return c.k2sContext
}
