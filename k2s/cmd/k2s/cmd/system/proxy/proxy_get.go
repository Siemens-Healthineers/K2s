// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"github.com/spf13/cobra"
)

var proxyGetCmd = &cobra.Command{
	Use:   "get",
	Short: "Get proxy information",
	Long:  "Get information about the proxy configuration",
	RunE:  getProxyServer,
}

func getProxyServer(cmd *cobra.Command, args []string) error {
	return nil
}
