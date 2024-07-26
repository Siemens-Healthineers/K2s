// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package clusterclient

import (
	"bytes"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

type K8sClientSet struct {
	Clientset kubernetes.Interface
	Config    *rest.Config
}

type PodSpec struct {
	NodeName          string
	PodName           string
	Namespace         string
	DeploymentNameRef string
}

type DeploymentItem struct {
	Name     string
	PodSpecs []PodSpec
}

type DeploymentSpec struct {
	Items     []DeploymentItem
	Namespace string
}

type PodCmdExecParam struct {
	Namespace string
	Pod       string
	Container string
	Command   []string
	Stdout    *bytes.Buffer
	Stderr    *bytes.Buffer
}

// utility
func GroupPodsByNode(deploymentItems []DeploymentItem) map[string][]PodSpec {
	allPods := []PodSpec{}
	for _, item := range deploymentItems {
		allPods = append(allPods, item.PodSpecs...)
	}

	nodeMap := make(map[string][]PodSpec)
	for _, pod := range allPods {
		nodeMap[pod.NodeName] = append(nodeMap[pod.NodeName], pod)
	}
	return nodeMap
}
