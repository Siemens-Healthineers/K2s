// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var proxyResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset the proxy settings",
	Long:  "This command resets the proxy settings to their default values.",
	RunE:  resetProxyConfig,
}

func resetProxyConfig(cmd *cobra.Command, args []string) error {
	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	err := proxyConfigHandler.Reset()

	if err != nil {
		return fmt.Errorf("error occurred while resetting proxy settings: %v", err)
	}

	return nil
}
