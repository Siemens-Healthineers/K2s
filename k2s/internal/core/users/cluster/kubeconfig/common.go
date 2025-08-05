// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

import "github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"

type kubeconfigReader interface {
	ReadCurrentKubeconfig() (*kubeconfig.Kubeconfig, error)
	ReadKubeconfig(path string) (*kubeconfig.Kubeconfig, error)
}
