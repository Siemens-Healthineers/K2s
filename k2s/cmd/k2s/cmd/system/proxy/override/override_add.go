// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"github.com/spf13/cobra"
)

var overrideAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add an override",
	RunE:  overrideAdd,
}

func overrideAdd(cmd *cobra.Command, args []string) error {
	return nil
}
