// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package status

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type LoadedStatus struct {
	common.CmdResult
	RunningState   *RunningState   `json:"runningState"`
	Nodes          []Node          `json:"nodes"`
	Pods           []Pod           `json:"pods"`
	K8sVersionInfo *K8sVersionInfo `json:"k8sVersionInfo"`
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
	Status           string   `json:"status"`
	Name             string   `json:"name"`
	Role             string   `json:"role"`
	Age              string   `json:"age"`
	KubeletVersion   string   `json:"kubeletVersion"`
	KernelVersion    string   `json:"kernelVersion"`
	OsImage          string   `json:"osImage"`
	ContainerRuntime string   `json:"containerRuntime"`
	InternalIp       string   `json:"internalIp"`
	IsReady          bool     `json:"isReady"`
	Capacity         Capacity `json:"capacity"`
}

type RunningState struct {
	IsRunning bool     `json:"isRunning"`
	Issues    []string `json:"issues"`
}

type K8sVersionInfo struct {
	K8sServerVersion string `json:"k8sServerVersion"`
	K8sClientVersion string `json:"k8sClientVersion"`
}

type Capacity struct {
	Cpu     string `json:"cpu"`
	Storage string `json:"storage"`
	Memory  string `json:"memory"`
}

func LoadStatus(psVersion powershell.PowerShellVersion) (*LoadedStatus, error) {
	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return nil, err
	}

	scriptPath := utils.FormatScriptFilePath(utils.InstallDir() + `\lib\scripts\k2s\status\Get-Status.ps1`)

	return powershell.ExecutePsWithStructuredResult[*LoadedStatus](scriptPath, "CmdResult", psVersion, outputWriter)
}
