// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"github.com/spf13/cobra"
)

var overrideDeleteCmd = &cobra.Command{
	Use:   "delete",
	Short: "Delete an override",
	RunE:  overrideDelete,
}

func overrideDelete(cmd *cobra.Command, args []string) error {
	return nil
}
