// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
)

type kubeconfigCredentialsFinder interface {
	FindK8sApiCredentials(config *kubeconfig.Kubeconfig, contextName string) (*kubeconfig.ClusterConfig, *kubeconfig.UserConfig, error)
}

type KubeconfigReader struct {
	config                      *config.KubeConfig
	kubeconfigReader            kubeconfigReader
	kubeconfigCredentialsFinder kubeconfigCredentialsFinder
}

func NewKubeconfigReader(config *config.KubeConfig, kubeconfigReader kubeconfigReader, kubeconfigCredentialsFinder kubeconfigCredentialsFinder) *KubeconfigReader {
	return &KubeconfigReader{
		config:                      config,
		kubeconfigReader:            kubeconfigReader,
		kubeconfigCredentialsFinder: kubeconfigCredentialsFinder,
	}
}

func (k *KubeconfigReader) ReadK8sApiCredentials(context, kubeconfigPath string) (clusterConfig *kubeconfig.ClusterConfig, userConfig *kubeconfig.UserConfig, err error) {
	slog.Debug("Reading Kubernetes API credentials from kubeconfig", "context", context, "kubeconfig-path", kubeconfigPath)

	kubeConfig, err := k.kubeconfigReader.ReadKubeconfig(kubeconfigPath)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to read kubeconfig '%s': %w", kubeconfigPath, err)
	}

	clusterConfig, userConfig, err = k.kubeconfigCredentialsFinder.FindK8sApiCredentials(kubeConfig, context)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to find Kubernetes API credentials in kubeconfig '%s' for context '%s': %w", kubeconfigPath, context, err)
	}

	slog.Debug("Kubernetes API credentials read from kubeconfig", "context", context, "kubeconfig-path", kubeconfigPath)
	return
}

func (k *KubeconfigReader) ReadCurrentContext(kubeconfigPath string) (string, error) {
	slog.Debug("Reading Kubernetes current context from kubeconfig", "kubeconfig-path", kubeconfigPath)

	kubeConfig, err := k.kubeconfigReader.ReadKubeconfig(kubeconfigPath)
	if err != nil {
		return "", fmt.Errorf("failed to read kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("Kubernetes current context read from kubeconfig", "context", kubeConfig.CurrentContext, "kubeconfig-path", kubeconfigPath)

	return kubeConfig.CurrentContext, nil
}
