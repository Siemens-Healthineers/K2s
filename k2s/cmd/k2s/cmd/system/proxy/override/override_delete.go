// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"

	"github.com/spf13/cobra"
)

var overrideDeleteCmd = &cobra.Command{
	Use:   "delete",
	Short: "Delete an override",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your logic here to delete the override
		fmt.Println("Override deleted")
	},
}
