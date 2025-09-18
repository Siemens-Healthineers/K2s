// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
)

type kubectl interface {
	Exec(args ...string) error
}

type KubeconfigWriter struct {
	config  *config.KubeConfig
	kubectl kubectl
}

func NewKubeconfigWriter(config *config.KubeConfig, kubectl kubectl) *KubeconfigWriter {
	return &KubeconfigWriter{
		config:  config,
		kubectl: kubectl,
	}
}

func (k *KubeconfigWriter) SetClusterConfig(config *kubeconfig.ClusterConfig, kubeconfigPath string) error {
	slog.Debug("Setting cluster config", "cluster-name", config.Name, "kubeconfig-path", kubeconfigPath)

	targetDir := filepath.Dir(kubeconfigPath)
	certJsonPath := fmt.Sprintf("clusters.%s.certificate-authority-data", config.Name)

	if err := os.MkdirAll(targetDir, fs.ModePerm); err != nil {
		return fmt.Errorf("failed to prepare target directory '%s': %w", kubeconfigPath, err)
	}

	// implicitly creates kubeconfig when not existing
	if err := k.kubectl.Exec("config", "set-cluster", config.Name, "--server", config.Server, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set cluster '%s' in kubeconfig '%s': %w", config.Name, kubeconfigPath, err)
	}

	// "kubectl config set-cluster" does not support in-memory cert data, therefor the cert data is set separately
	if err := k.kubectl.Exec("config", "set", certJsonPath, config.Cert, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set cluster certificate in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("Cluster config set", "cluster-name", config.Name, "kubeconfig-path", kubeconfigPath)
	return nil
}

func (k *KubeconfigWriter) SetUserCredentials(k8sUserName, certPath, keyPath, kubeconfigPath string) error {
	slog.Debug("Setting user credentials", "k8s-user-name", k8sUserName, "cert-path", certPath, "key-path", keyPath, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "set-credentials", k8sUserName, "--client-certificate", certPath, "--client-key", keyPath, "--embed-certs=true", "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set user credentials in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("User credentials set for user", "k8s-user-name", k8sUserName, "cert-path", certPath, "key-path", keyPath, "kubeconfig-path", kubeconfigPath)
	return nil
}

func (k *KubeconfigWriter) SetContext(context, k8sUserName, clusterName, kubeconfigPath string) error {
	slog.Debug("Setting context for user", "k8s-user-name", k8sUserName, "cluster-name", clusterName, "context", context, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "set-context", context, "--cluster="+clusterName, "--user="+k8sUserName, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set context in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("K2s context set", "k8s-user-name", k8sUserName, "cluster-name", clusterName, "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}

func (k *KubeconfigWriter) SetCurrentContext(context, kubeconfigPath string) error {
	slog.Debug("Setting current context", "context", context, "kubeconfig-path", kubeconfigPath)

	if err := k.kubectl.Exec("config", "use-context", context, "--kubeconfig", kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set current context in kubeconfig '%s': %w", kubeconfigPath, err)
	}

	slog.Debug("Current context set", "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}
