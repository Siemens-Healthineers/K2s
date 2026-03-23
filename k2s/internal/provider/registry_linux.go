// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

// NewRegistry creates a Registry populated with Linux-specific providers.
// Linux providers use native commands (kubeadm, kubectl, crictl, virsh, ssh).
func NewRegistry(cfg ProviderConfig) *Registry {
	return &Registry{
		Cluster: newLinuxClusterProvider(cfg),
		Image:   newLinuxImageProvider(cfg),
		Node:    newLinuxNodeProvider(cfg),
		System:  newLinuxSystemProvider(cfg),
		Addon:   newLinuxAddonProvider(cfg),
	}
}
