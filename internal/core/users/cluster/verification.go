// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cluster

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
)

type kubeconfigReader interface {
	ReadK8sApiCredentials(context, kubeconfigPath string) (clusterConfig *kubeconfig.ClusterConfig, userConfig *kubeconfig.UserConfig, err error)
	ReadCurrentContext(kubeconfigPath string) (string, error)
}

type credentialsDecoder interface {
	DecodeK8sApiCredentials(clusterConfig *kubeconfig.ClusterConfig, userConfig *kubeconfig.UserConfig) (caCert, userCert, userKey []byte, err error)
}

type apiAccessVerifier interface {
	VerifyAccess(userName, server string, caCert, userCert, userKey []byte) error
}

type ClusterAccessVerifier struct {
	kubeconfigReader   kubeconfigReader
	credentialsDecoder credentialsDecoder
	apiAccessVerifier  apiAccessVerifier
}

func NewClusterAccessVerifier(kubeconfigReader kubeconfigReader, credentialsDecoder credentialsDecoder, apiAccessVerifier apiAccessVerifier) *ClusterAccessVerifier {
	return &ClusterAccessVerifier{
		kubeconfigReader:   kubeconfigReader,
		credentialsDecoder: credentialsDecoder,
		apiAccessVerifier:  apiAccessVerifier,
	}
}

func (c *ClusterAccessVerifier) VerifyAccess(context, kubeconfigPath string) error {
	slog.Debug("Verifying cluster access", "context", context, "kubeconfig-path", kubeconfigPath)

	clusterConfig, userConfig, err := c.kubeconfigReader.ReadK8sApiCredentials(context, kubeconfigPath)
	if err != nil {
		return fmt.Errorf("failed to read Kubernetes API credentials from kubeconfig '%s': %w", kubeconfigPath, err)
	}

	caCert, userCert, userKey, err := c.credentialsDecoder.DecodeK8sApiCredentials(clusterConfig, userConfig)
	if err != nil {
		return fmt.Errorf("failed to decode Kubernetes API credentials: %w", err)
	}

	if c.apiAccessVerifier.VerifyAccess(userConfig.Name, clusterConfig.Server, caCert, userCert, userKey) != nil {
		return fmt.Errorf("failed to verify Kubernetes API access for user '%s'", userConfig.Name)
	}

	slog.Debug("Kubernetes cluster verified", "context", context, "kubeconfig-path", kubeconfigPath)
	return nil
}
