// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import "github.com/spf13/cobra"

var proxyShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show proxy information",
	Long:  "This command shows information about the proxy",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your code here to implement the functionality of the command
	},
}
