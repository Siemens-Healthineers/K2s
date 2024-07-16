// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"fmt"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var proxyGetCmd = &cobra.Command{
	Use:   "get",
	Short: "Get proxy information",
	Long:  "Get information about the proxy configuration",
	RunE:  getProxyServer,
}

func getProxyServer(cmd *cobra.Command, args []string) error {
	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	proxyConfig, err := proxyConfigHandler.ReadConfig()

	if err != nil {
		return fmt.Errorf("unable to display proxy server settings due to error: %v", err)
	}

	pterm.Println(fmt.Sprintf("HTTP_PROXY=%v", proxyConfig.HttpProxy))
	pterm.Println(fmt.Sprintf("HTTP_PROXY=%v", proxyConfig.HttpsProxy))

	return nil
}
