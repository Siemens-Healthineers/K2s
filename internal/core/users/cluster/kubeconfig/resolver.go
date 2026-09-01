// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import (
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
)

type KubeconfigResolver struct {
	kubeConfig *config.KubeConfig
}

func NewKubeconfigResolver(kubeConfig *config.KubeConfig) *KubeconfigResolver {
	return &KubeconfigResolver{

		kubeConfig: kubeConfig,
	}
}

func (k *KubeconfigResolver) ResolveKubeconfigPath(user *users.OSUser) string {
	targetDir := host.ResolveTildePrefix(k.kubeConfig.RelativeDir(), user.HomeDir())

	return filepath.Join(targetDir, definitions.KubeconfigName)
}
