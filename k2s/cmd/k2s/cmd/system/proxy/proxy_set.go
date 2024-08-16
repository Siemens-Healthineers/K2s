// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"github.com/spf13/cobra"
)

var proxySetCmd = &cobra.Command{
	Use:   "set",
	Short: "Set the proxy configuration",
	Long:  "Set the proxy configuration for the application",
	RunE:  setProxyServer,
}

func setProxyServer(cmd *cobra.Command, args []string) error {
	return nil
}
