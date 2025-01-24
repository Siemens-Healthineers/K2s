// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"github.com/spf13/cobra"
)

var proxyShowCmd = &cobra.Command{
	Use:   "show",
	Short: "Show proxy information",
	Long:  "This command shows information about the proxy",
	RunE:  showProxyConfig,
}

func showProxyConfig(cmd *cobra.Command, args []string) error {
	return nil
}
