// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package start

import (
	"github.com/spf13/cobra"
)

// startLinux is a no-op on Windows. Returns errNotLinux to fall through.
func startLinux(_ *cobra.Command) error {
	return errNotLinux
}
