// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var overrideAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add an override",
	RunE:  overrideAdd,
}

func overrideAdd(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("incorrect number of arguments specified")
	}

	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	currentProxyConfig, err := proxyConfigHandler.ReadConfig()
	if err != nil {
		return err
	}

	newProxyConfig := currentProxyConfig

	// Create a map for faster lookup of existing noProxy entries
	existingNoProxy := make(map[string]bool)
	for _, entry := range currentProxyConfig.NoProxy {
		existingNoProxy[entry] = true
	}

	// Append only new args that do not exist in currentProxyConfig.NoProxy
	for _, arg := range args {
		if _, exists := existingNoProxy[arg]; !exists {
			newProxyConfig.NoProxy = append(newProxyConfig.NoProxy, arg)
		}
	}

	err = proxyConfigHandler.SaveConfig(newProxyConfig)
	if err != nil {
		return err
	}

	return nil
}
