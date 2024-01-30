// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	"k2s/setupinfo"
	"k2s/utils"
)

type StatusLoader struct {
}

type Status struct {
	// TODO: separate cluster status and addons status
	EnabledAddons  []string            `json:"enabledAddons"`
	SetupInfo      setupinfo.SetupInfo `json:"setupInfo"`
	RunningState   *RunningState       `json:"runningState"`
	Nodes          []Node              `json:"nodes"`
	Pods           []Pod               `json:"pods"`
	K8sVersionInfo *K8sVersionInfo     `json:"k8sVersionInfo"`
}

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

func LoadStatus() (*Status, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + `\lib\scripts\k2s\status\Get-Status.ps1`)

	status, err := utils.ExecutePsWithStructuredResult[Status](scriptPath, "Status", utils.ExecOptions{})
	if err != nil {
		if err != setupinfo.ErrNotInstalled {
			return nil, err
		}
		errMsg := setupinfo.ErrNotInstalledMsg
		status = Status{SetupInfo: setupinfo.SetupInfo{Error: &errMsg}}
	}

	return &status, nil
}
