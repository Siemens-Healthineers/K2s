// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

// Package setuporchestration defines the platform-abstraction interfaces for
// cluster lifecycle operations. Each host OS (Windows, Linux) provides its own
// implementation.
//
// On Windows the orchestration delegates to PowerShell scripts (existing behavior).
// On Linux the orchestration calls native kubeadm/systemd/libvirt directly.
package setuporchestration
