// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker

type NetworkCheckType string

const (
	PodToPodWithinNode  NetworkCheckType = "PodToPodWithinNode"
	PodToPodAcrossNode  NetworkCheckType = "PodToPodAcrossNode"
	HostToPodWithinNode NetworkCheckType = "HostToPodWithinNode"
	HostToPodAcrossNode NetworkCheckType = "HostToPodAcrossNode"
	PodToInternet       NetworkCheckType = "PodToInternet"
)

const (
	StatusOK   = "OK"
	StatusFail = "FAIL"
)

type NetworkCheckResult struct {
	Command   string
	Status    string
	Error     string
	SourcePod string
	TargetPod string
	CheckType NetworkCheckType
}
