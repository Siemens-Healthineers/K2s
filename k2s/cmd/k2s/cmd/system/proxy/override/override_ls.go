// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"github.com/spf13/cobra"
)

var overrideListCmd = &cobra.Command{
	Use:   "ls",
	Short: "List all overrides",
	Long:  "List all overrides in the system",
	RunE:  listProxyOverrides,
}

func listProxyOverrides(cmd *cobra.Command, args []string) error {
	return nil
}
