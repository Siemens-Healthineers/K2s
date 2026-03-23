// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package provider

// NodeProvider abstracts node management operations.
// On Windows: delegates to PowerShell scripts.
// On Linux: uses SSH + kubeadm join natively.
type NodeProvider interface {
	// Add adds a worker node to the cluster.
	Add(config NodeAddConfig) error

	// Remove removes a worker node from the cluster.
	Remove(config NodeRemoveConfig) error
}

// NodeAddConfig holds parameters for adding a node.
type NodeAddConfig struct {
	NodeType   string // "windows" or "linux"
	IpAddress  string
	ShowOutput bool
}

// NodeRemoveConfig holds parameters for removing a node.
type NodeRemoveConfig struct {
	NodeName   string
	ShowOutput bool
}
