// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package uninstall

import (
	"github.com/spf13/cobra"
)

// uninstallLinux is a no-op on Windows. Returns errNotLinux to fall through.
func uninstallLinux(_ *cobra.Command) error {
	return errNotLinux
}
