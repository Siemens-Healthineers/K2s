// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "users",
		Short: "K2s users management (host only)",
	}

	cmd.AddCommand(newAddCommand())

	return cmd
}
