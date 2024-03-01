// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

type Pod struct {
	Status    string `json:"status"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Ready     string `json:"ready"`
	Restarts  string `json:"restarts"`
	Age       string `json:"age"`
	Ip        string `json:"ip"`
	Node      string `json:"node"`
	IsRunning bool   `json:"isRunning"`
}

type Node struct {
	Status           string `json:"status"`
	Name             string `json:"name"`
	Role             string `json:"role"`
	Age              string `json:"age"`
	KubeletVersion   string `json:"kubeletVersion"`
	KernelVersion    string `json:"kernelVersion"`
	OsImage          string `json:"osImage"`
	ContainerRuntime string `json:"containerRuntime"`
	InternalIp       string `json:"internalIp"`
	IsReady          bool   `json:"isReady"`
}

type RunningState struct {
	IsRunning bool     `json:"isRunning"`
	Issues    []string `json:"issues"`
}

type K8sVersionInfo struct {
	K8sServerVersion string `json:"k8sServerVersion"`
	K8sClientVersion string `json:"k8sClientVersion"`
}
