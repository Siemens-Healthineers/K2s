// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	contracts "github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/providers/kubeconfig"
)

type KubeconfigReader struct {
	currentPath string
}

func NewKubeconfigReader(config *config.KubeConfig) *KubeconfigReader {
	return &KubeconfigReader{
		currentPath: config.CurrentPath(),
	}
}

func (k *KubeconfigReader) ReadCurrentKubeconfig() (*contracts.Kubeconfig, error) {
	return k.ReadKubeconfig(k.currentPath)
}

func (k *KubeconfigReader) ReadKubeconfig(path string) (*contracts.Kubeconfig, error) {
	return kubeconfig.ReadFile(path)
}
