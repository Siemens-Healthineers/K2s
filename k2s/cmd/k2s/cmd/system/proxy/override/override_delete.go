// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var overrideDeleteCmd = &cobra.Command{
	Use:   "delete",
	Short: "Delete an override",
	RunE:  overrideDelete,
}

func overrideDelete(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("incorrect number of arguments specified")
	}

	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	currentProxyConfig, err := proxyConfigHandler.ReadConfig()
	if err != nil {
		return err
	}

	newProxyConfig := currentProxyConfig

	// Convert NoProxy slice to a map for efficient lookup and removal
	noProxyMap := make(map[string]bool)
	for _, entry := range currentProxyConfig.NoProxy {
		noProxyMap[entry] = true
	}

	// Remove args that exist in currentProxyConfig.NoProxy
	for _, arg := range args {
		if _, exists := noProxyMap[arg]; exists {
			delete(noProxyMap, arg)
		}
	}

	// Convert map back to slice for the newProxyConfig
	newNoProxy := make([]string, 0, len(noProxyMap))
	for entry := range noProxyMap {
		newNoProxy = append(newNoProxy, entry)
	}
	newProxyConfig.NoProxy = newNoProxy

	err = proxyConfigHandler.SaveConfig(newProxyConfig)
	if err != nil {
		return err
	}

	return nil
}
