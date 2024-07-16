// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"fmt"
	"strings"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var proxyShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show proxy information",
	Long:  "This command shows information about the proxy",
	RunE:  showProxyConfig,
}

func showProxyConfig(cmd *cobra.Command, args []string) error {
	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	proxyConfig, err := proxyConfigHandler.ReadConfig()

	if err != nil {
		return fmt.Errorf("unable to display proxy settings due to error: %v", err)
	}

	pterm.Println(fmt.Sprintf("HTTP_PROXY=%v", proxyConfig.HttpProxy))
	pterm.Println(fmt.Sprintf("HTTP_PROXY=%v", proxyConfig.HttpsProxy))
	pterm.Println(fmt.Sprintf("NO_PROXY=%v", strings.Join(proxyConfig.NoProxy, ",")))

	return nil
}
