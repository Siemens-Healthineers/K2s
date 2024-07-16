// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var proxySetCmd = &cobra.Command{
	Use:   "set",
	Short: "Set the proxy configuration",
	Long:  "Set the proxy configuration for the application",
	RunE:  setProxyServer,
}

func setProxyServer(cmd *cobra.Command, args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("incorrect number of arguments specified")
	}

	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	currentProxyConfig, err := proxyConfigHandler.ReadConfig()
	if err != nil {
		return err
	}

	newProxyConfig := currentProxyConfig
	newProxyConfig.HttpProxy = args[0]
	newProxyConfig.HttpsProxy = args[0]

	err = proxyConfigHandler.SaveConfig(newProxyConfig)
	if err != nil {
		return err
	}

	return nil
}
