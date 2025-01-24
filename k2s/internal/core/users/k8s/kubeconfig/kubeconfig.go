// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
	bkc "github.com/siemens-healthineers/k2s/internal/k8s/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/primitives/arrays"
)

type kubeconfigWriter struct {
	path string
	exec common.CmdExecutor
}

func NewKubeconfigWriter(filePath string, cmdExecutor common.CmdExecutor) *kubeconfigWriter {
	return &kubeconfigWriter{
		path: filePath,
		exec: cmdExecutor,
	}
}

func (k *kubeconfigWriter) FilePath() string {
	return k.path
}

func (k *kubeconfigWriter) SetCluster(clusterConfig *bkc.ClusterEntry) error {
	slog.Debug("Setting cluster in kubeconfig", "path", k.path)

	// implicitly creates kubeconfig when not existing
	if err := k.execConfCmd("set-cluster", clusterConfig.Name, "--server", clusterConfig.Details.Server); err != nil {
		return fmt.Errorf("could not set cluster config: %w", err)
	}

	certJsonPath := fmt.Sprintf("clusters.%s.certificate-authority-data", clusterConfig.Name)

	// "kubectl config set-cluster" does not support in-memory cert data, therefor the cert data is set separately
	if err := k.execConfCmd("set", certJsonPath, clusterConfig.Details.Cert); err != nil {
		return fmt.Errorf("could not set cluster cert config: %w", err)
	}
	return nil
}

func (k *kubeconfigWriter) SetCredentials(username, certPath, keyPath string) error {
	slog.Debug("Setting credentials in kubeconfig", "path", k.path, "username", username, "cert-path", certPath, "key-path", keyPath)

	if err := k.execConfCmd("set-credentials", username, "--client-certificate", certPath, "--client-key", keyPath, "--embed-certs=true"); err != nil {
		return fmt.Errorf("could not set user credentials: %w", err)
	}
	return nil
}

func (k *kubeconfigWriter) SetContext(context, username, clusterName string) error {
	slog.Debug("Setting context in kubeconfig", "path", k.path, "context", context, "username", username, "cluster-name", clusterName)

	clusterParam := "--cluster=" + clusterName
	userParam := "--user=" + username

	if err := k.execConfCmd("set-context", context, clusterParam, userParam); err != nil {
		return fmt.Errorf("could not set context '%s': %w", context, err)
	}
	return nil
}

func (k *kubeconfigWriter) UseContext(context string) error {
	slog.Debug("Setting active context in kubeconfig", "path", k.path, "context", context)

	if err := k.execConfCmd("use-context", context); err != nil {
		return fmt.Errorf("could not use context '%s': %w", context, err)
	}
	return nil
}

func (k *kubeconfigWriter) execConfCmd(params ...string) error {
	slog.Debug("Executing 'kubectl config' cmd", "params-len", len(params))

	params = arrays.Insert(params, "config", 0)
	params = append(params, "--kubeconfig", k.path)

	if err := k.exec.ExecuteCmd("kubectl", params...); err != nil {
		return fmt.Errorf("could not execute 'kubectl config' cmd: %w", err)
	}
	return nil
}
