// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import "github.com/spf13/cobra"

var proxyResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset the proxy settings",
	Long:  "This command resets the proxy settings to their default values.",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your code here to reset the proxy settings
	},
}
