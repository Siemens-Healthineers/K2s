// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package install

import (
	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"
	"github.com/spf13/cobra"
)

// installLinux is a no-op on Windows. Returns a sentinel error to signal
// the caller should continue with the PowerShell-based install path.
func installLinux(_ *cobra.Command, _ *ic.InstallConfig) error {
	return errNotLinux
}
