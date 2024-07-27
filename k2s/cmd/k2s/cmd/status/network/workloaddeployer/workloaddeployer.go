// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package workloaddeployer

import (
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
	cmdexecutor "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/cmdexecutor"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

type WorkloadDeployer struct {
	kubectlCli cmdexecutor.CmdExecutor
	client     *clusterclient.K8sClientSet
}

type DeployParam struct {
	Namespace string
	NodeNames []string
}

func NewWorkloadDeployer(kubectlCli cmdexecutor.CmdExecutor, client clusterclient.K8sClientSet) *WorkloadDeployer {
	return &WorkloadDeployer{kubectlCli: kubectlCli, client: &client}
}

func (w *WorkloadDeployer) Deploy(param DeployParam) error {
	manifestDir := resolveManifestDirFromNodes(param.NodeNames)

	status := w.kubectlCli.ExecCmd("apply", "-k", manifestDir)
	if status.Err != nil {
		slog.Error("Error during deployment", "error", status.Err)
		return status.Err
	}

	status = w.kubectlCli.ExecCmd("rollout", "status", "deployment", "-n", param.Namespace)
	if status.Err != nil {
		slog.Error("Rollout of network probes failed", "error", status.Err)
		return status.Err
	}

	return nil
}

func (w *WorkloadDeployer) Remove(param DeployParam) error {
	manifestDir := resolveManifestDirFromNodes(param.NodeNames)

	status := w.kubectlCli.ExecCmd("delete", "-k", manifestDir)
	if status.Err != nil {
		slog.Error("Error during removal of deployment", "error", status.Err)
		return status.Err
	}

	return nil
}

func (w *WorkloadDeployer) GetNodeGroups(namespace string) (map[string][]clusterclient.PodSpec, error) {
	deployment, err := w.client.GetDeployments(namespace)
	if err != nil {
		slog.Error("Error getting deployments", "error", err)
		return nil, err
	}

	// Wait for deployment
	for _, deploymentItem := range deployment.Items {
		slog.Debug("Deployment Name: %s | Pod Count: %d", deploymentItem.Name, len(deploymentItem.PodSpecs))
		w.client.WaitForDeploymentReady(namespace, deploymentItem.Name)
	}

	return clusterclient.GroupPodsByNode(deployment.Items), nil
}

func resolveManifestDirFromNodes(nodes []string) string {
	rootDir := utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\"

	if len(nodes) == 1 {
		// single node
		if nodes[0] == "kubemaster" {
			return rootDir + "workload\\linux"
		} else {
			return rootDir + "workload\\windows"
		}
	}

	return rootDir + "workload"
}
