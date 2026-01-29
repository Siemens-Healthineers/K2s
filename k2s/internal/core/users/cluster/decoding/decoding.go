// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package decoding

import (
	"encoding/base64"
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
)

type CredentialsDecoder struct {
}

func NewCredentialsDecoder() *CredentialsDecoder {
	return &CredentialsDecoder{}
}

func (c *CredentialsDecoder) DecodeK8sApiCredentials(clusterConfig *kubeconfig.ClusterConfig, userConfig *kubeconfig.UserConfig) (caCert, userCert, userKey []byte, err error) {
	slog.Debug("Decoding Kubernetes API credentials")

	caCert, err = base64.StdEncoding.DecodeString(clusterConfig.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode cluster certificate: %w", err)
	}

	userCert, err = base64.StdEncoding.DecodeString(userConfig.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode user certificate: %w", err)
	}

	userKey, err = base64.StdEncoding.DecodeString(userConfig.Key)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode user key: %w", err)
	}

	slog.Debug("Kubernetes API credentials decoded")
	return
}
