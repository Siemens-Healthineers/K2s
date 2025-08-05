// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
)

type clusterFinder interface {
	FindK2sCluster(kubeconfig *kubeconfig.Kubeconfig) (*kubeconfig.ClusterConfig, error)
}

type clusterConfigWriter interface {
	SetClusterConfig(config *kubeconfig.ClusterConfig, kubeconfigPath string) error
}

type KubeconfigCopier struct {
	kubeconfigReader    kubeconfigReader
	clusterFinder       clusterFinder
	clusterConfigWriter clusterConfigWriter
}

func NewKubeconfigCopier(kubeconfigReader kubeconfigReader, clusterFinder clusterFinder, clusterConfigWriter clusterConfigWriter) *KubeconfigCopier {
	return &KubeconfigCopier{
		kubeconfigReader:    kubeconfigReader,
		clusterFinder:       clusterFinder,
		clusterConfigWriter: clusterConfigWriter,
	}
}

func (k *KubeconfigCopier) CopyClusterConfig(targetPath string) error {
	slog.Debug("Copying current cluster config to target kubeconfig", "path", targetPath)

	sourceConfig, err := k.kubeconfigReader.ReadCurrentKubeconfig()
	if err != nil {
		return fmt.Errorf("failed to read current kubeconfig: %w", err)
	}

	clusterConfig, err := k.clusterFinder.FindK2sCluster(sourceConfig)
	if err != nil {
		return fmt.Errorf("failed to find cluster config: %w", err)
	}

	if err := k.clusterConfigWriter.SetClusterConfig(clusterConfig, targetPath); err != nil {
		return fmt.Errorf("failed to set cluster config in target '%s': %w", targetPath, err)
	}

	slog.Debug("Current cluster config copied to target kubeconfig", "path", targetPath)
	return nil
}
