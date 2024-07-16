// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"
	"strings"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/internal/proxy"
	"github.com/spf13/cobra"
)

var overrideListCmd = &cobra.Command{
	Use:   "ls",
	Short: "List all overrides",
	Long:  "List all overrides in the system",
	RunE:  listProxyOverrides,
}

func listProxyOverrides(cmd *cobra.Command, args []string) error {
	proxyConfigHandler := proxy.NewFileProxyConfigHandler("C:\\etc\\k2s\\proxy.conf")

	proxyConfig, err := proxyConfigHandler.ReadConfig()

	if err != nil {
		return fmt.Errorf("unable to display proxy overrides due to error: %v", err)
	}

	pterm.Println(fmt.Sprintf("%v", strings.Join(proxyConfig.NoProxy, ",")))

	return nil
}
