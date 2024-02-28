// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	"errors"
	"k2s/cmd/common"
	sc "k2s/cmd/status/common"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
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
