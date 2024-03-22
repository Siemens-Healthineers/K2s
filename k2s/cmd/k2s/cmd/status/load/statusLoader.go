// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	sc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type StatusLoader struct {
}

type LoadedStatus struct {
	common.CmdResult
	RunningState   *sc.RunningState   `json:"runningState"`
	Nodes          []sc.Node          `json:"nodes"`
	Pods           []sc.Pod           `json:"pods"`
	K8sVersionInfo *sc.K8sVersionInfo `json:"k8sVersionInfo"`
}

func LoadStatus(psVersion powershell.PowerShellVersion) (*LoadedStatus, error) {
	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return nil, err
	}

	scriptPath := utils.FormatScriptFilePath(utils.InstallDir() + `\lib\scripts\k2s\status\Get-Status.ps1`)

	return powershell.ExecutePsWithStructuredResult[*LoadedStatus](scriptPath, "CmdResult", psVersion, outputWriter)
}
