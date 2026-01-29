// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package hostprocess

// Centralized constants for host process e2e to avoid drift with manifests.
// If you change names in workload/windows-albums-cp.yaml update them here.
const (
	NamespaceHostProcess           = "k2s" // currently using default; adjust if manifest namespace changes
	AnchorPodName                  = "albums-compartment-anchor"
	HostProcessDeploymentName      = "albums-win-hp-app-hostprocess"
	HostProcessAppLabel            = "albums-win-hp-app-hostprocess" // value of the app label on the host process pods and service
	HostProcessServiceName         = "albums-win-hp-app-hostprocess"
	HostProcessServicePort         = 80   // service port
	HostProcessContainerTargetPort = 8080 // targetPort in the service (documented for reference)
)
