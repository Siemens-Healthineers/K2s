// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	"errors"

	sc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/setupinfo"
)

type StatusLoader struct {
}

type LoadedStatus struct {
	common.CmdResult
	SetupInfo      *setupinfo.SetupInfo `json:"setupInfo"`
	RunningState   *sc.RunningState     `json:"runningState"`
	Nodes          []sc.Node            `json:"nodes"`
	Pods           []sc.Pod             `json:"pods"`
	K8sVersionInfo *sc.K8sVersionInfo   `json:"k8sVersionInfo"`
}

func LoadStatus() (*LoadedStatus, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + `\lib\scripts\k2s\status\Get-Status.ps1`)

	status, err := psexecutor.ExecutePsWithStructuredResult[*LoadedStatus](scriptPath, "CmdResult", psexecutor.ExecOptions{})
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return nil, err
		}
		status = &LoadedStatus{CmdResult: common.CreateSystemNotInstalledCmdResult()}
	}
	return status, nil
}
