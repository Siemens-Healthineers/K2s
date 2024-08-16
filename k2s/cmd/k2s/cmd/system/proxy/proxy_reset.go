// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"github.com/spf13/cobra"
)

var proxyResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset the proxy settings",
	Long:  "This command resets the proxy settings to their default values.",
	RunE:  resetProxyConfig,
}

func resetProxyConfig(cmd *cobra.Command, args []string) error {
	return nil
}
