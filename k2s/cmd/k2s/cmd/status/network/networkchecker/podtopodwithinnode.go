// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker

import (
	"bytes"
	"log/slog"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
)

type PodToPodWithinNodeHandler struct {
	BaseNetworkChecker
	client clusterclient.K8sClientSet
	pod1   clusterclient.PodSpec
	pod2   clusterclient.PodSpec
}

func NewPodToPodWithinNodeHandler(client clusterclient.K8sClientSet, pod1, pod2 clusterclient.PodSpec) *PodToPodWithinNodeHandler {
	return &PodToPodWithinNodeHandler{client: client, pod1: pod1, pod2: pod2}
}

func (p *PodToPodWithinNodeHandler) CheckConnectivity() (*NetworkCheckResult, error) {

	slog.Debug("Checking connectivity between pod %s and pod %s within the same node\n", p.pod1.PodName, p.pod2.PodName)

	command := []string{"curl", "-i", "-m", "4", "http://" + p.pod2.DeploymentNameRef + "." + p.pod2.Namespace + ".svc.cluster.local/" + p.pod2.DeploymentNameRef}
	var stdout, stderr bytes.Buffer

	param := clusterclient.PodCmdExecParam{
		Namespace: p.pod1.Namespace,
		Pod:       p.pod1.PodName,
		Container: p.pod1.DeploymentNameRef,
		Command:   command,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	p.client.ExecuteCommand(param)

	httpStatus := strings.Split(param.Stdout.String(), "\n")[0]

	slog.Debug("Command < %s > executed with http status < %s >", strings.Join(param.Command, " "), httpStatus)

	result := strings.Contains(httpStatus, "200")
	status := StatusFail
	if result {
		status = StatusOK
	}

	checkResult := &NetworkCheckResult{
		CheckType: PodToPodWithinNode,
		Status:    status,
		Error:     stderr.String(),
		SourcePod: p.pod1.PodName,
		TargetPod: p.pod2.PodName,
	}
	p.NotifyObservers(checkResult)
	return p.CheckNext()
}
