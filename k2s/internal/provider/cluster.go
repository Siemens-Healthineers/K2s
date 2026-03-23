// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package provider

import k2sos "github.com/siemens-healthineers/k2s/internal/os"

// ClusterProvider abstracts cluster lifecycle operations.
// On Windows: delegates to PowerShell scripts.
// On Linux: uses kubeadm, systemctl, libvirt natively.
type ClusterProvider interface {
	// Install provisions the K2s cluster.
	Install(config ClusterInstallConfig) error

	// Uninstall tears down the cluster and removes all K2s resources.
	Uninstall(config ClusterUninstallConfig) error

	// Start brings up a previously stopped cluster.
	Start(config ClusterStartConfig) error

	// Stop gracefully stops the cluster.
	Stop(config ClusterStopConfig) error

	// Status loads the cluster status.
	Status(config ClusterStatusConfig) (*ClusterStatus, error)
}

// ClusterInstallConfig holds parameters for cluster installation.
type ClusterInstallConfig struct {
	MasterVMProcessorCount string
	MasterVMMemory         string
	MasterVMMemoryMin      string
	MasterVMMemoryMax      string
	MasterDiskSize         string
	DynamicMemory          bool
	LinuxOnly              bool
	WSL                    bool
	ShowLogs               bool
	SkipStart              bool
	ForceOnlineInstallation         bool
	DeleteFilesForOfflineInstallation bool
	AppendLog              bool
	Proxy                  string
	NoProxy                []string
	AdditionalHooksDir     string
	K8sBinsPath            string
	RestartPostInstall     string
	ConfigDir              string
	InstallDir             string
	Version                string
	ClusterName            string
	ControlPlaneHostname   string
	// StdWriter overrides the default writer for capturing PS output (Windows).
	// Linux providers ignore this field.
	StdWriter              k2sos.StdWriter
}

// ClusterUninstallConfig holds parameters for cluster uninstallation.
type ClusterUninstallConfig struct {
	ShowLogs                          bool
	SkipPurge                         bool
	DeleteFilesForOfflineInstallation bool
	AdditionalHooksDir                string
	ConfigDir                         string
	SetupName                         string
	LinuxOnly                         bool
}

// ClusterStartConfig holds parameters for starting the cluster.
type ClusterStartConfig struct {
	ShowLogs            bool
	AdditionalHooksDir  string
	UseCachedK2sVSwitch bool
	SetupName           string
	LinuxOnly           bool
}

// ClusterStopConfig holds parameters for stopping the cluster.
type ClusterStopConfig struct {
	ShowLogs           bool
	AdditionalHooksDir string
	CacheVSwitch       bool
	SetupName          string
	LinuxOnly          bool
}

// ClusterStatusConfig holds parameters for loading cluster status.
type ClusterStatusConfig struct {
	// ShowOutput controls whether PS scripts emit verbose output (Windows only).
	ShowOutput bool
}

// ClusterStatus holds the loaded cluster status.
type ClusterStatus struct {
	IsRunning      bool
	Issues         []string
	Nodes          []NodeStatus
	Pods           []PodStatus
	K8sVersionInfo *K8sVersionInfo
}

// K8sVersionInfo holds Kubernetes version information.
type K8sVersionInfo struct {
	K8sServerVersion string
	K8sClientVersion string
}

// NodeStatus holds status information for a single node.
type NodeStatus struct {
	Name             string
	Status           string
	Role             string
	Age              string
	KubeletVersion   string
	KernelVersion    string
	OsImage          string
	ContainerRuntime string
	InternalIp       string
	IsReady          bool
	Capacity         NodeCapacity
}

// NodeCapacity holds resource capacity for a node.
type NodeCapacity struct {
	Cpu     string
	Storage string
	Memory  string
}

// PodStatus holds status information for a single pod.
type PodStatus struct {
	Name      string
	Namespace string
	Status    string
	Ready     string
	Restarts  string
	Age       string
	Ip        string
	Node      string
	IsRunning bool
}
