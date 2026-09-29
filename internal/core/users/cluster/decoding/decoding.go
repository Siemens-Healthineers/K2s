// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package decoding

import (
	"encoding/base64"
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/providers/kubeconfig"
)

func DecodeK8sApiCredentials(clusterConfig *kubeconfig.Cluster, userConfig *kubeconfig.User) (caCert, userCert, userKey []byte, err error) {
	slog.Debug("Decoding Kubernetes API credentials")

	caCert, err = base64.StdEncoding.DecodeString(clusterConfig.Details.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode cluster certificate: %w", err)
	}

	userCert, err = base64.StdEncoding.DecodeString(userConfig.Details.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode user certificate: %w", err)
	}

	userKey, err = base64.StdEncoding.DecodeString(userConfig.Details.Key)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to decode user key: %w", err)
	}

	slog.Debug("Kubernetes API credentials decoded")
	return
}
