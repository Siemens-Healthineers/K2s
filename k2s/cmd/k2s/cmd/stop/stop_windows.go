// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package stop

import (
	"github.com/spf13/cobra"
)

// stopLinux is a no-op on Windows. Returns errNotLinux to fall through.
func stopLinux(_ *cobra.Command) error {
	return errNotLinux
}
