// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package factory

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
	cmdexecutor "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/cmdexecutor"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/config"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/workloaddeployer"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

type ClusterFactory struct {
	Config *config.Config
	Client *clusterclient.K8sClientSet
}

func NewClusterFactory(cfg *config.Config) (*ClusterFactory, error) {
	client, err := clusterclient.NewDefaultK8sClient(cfg.KubeConfig)
	if err != nil {
		return nil, err
	}

	return &ClusterFactory{
		Config: cfg,
		Client: client,
	}, nil
}

func (f *ClusterFactory) CreateWorkloadDeployer() *workloaddeployer.WorkloadDeployer {
	kubectlCli := cmdexecutor.NewKubectlCli(utils.InstallDir())
	return workloaddeployer.NewWorkloadDeployer(kubectlCli, *f.Client)
}
