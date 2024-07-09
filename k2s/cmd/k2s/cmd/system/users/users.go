// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "users",
		Short: "EXPERIMENTAL - K2s users management",
	}

	cmd.AddCommand(newAddCommand())

	return cmd
}
