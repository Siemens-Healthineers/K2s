// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/terminal"
	"github.com/spf13/cobra"
)

type ProxyServer struct {
	common.CmdResult
	Proxy *string `json:"proxy"`
}

var proxyGetCmd = &cobra.Command{
	Use:   "get",
	Short: "Get proxy information",
	Long:  "Get information about the proxy configuration",
	RunE:  getProxyServer,
}

func getProxyServer(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		return err
	}

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "GetProxy.ps1"))
	var params []string
	proxy, err := powershell.ExecutePsWithStructuredResult[*ProxyServer](psCmd, "ProxyServer", common.DeterminePsVersion(config), common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	terminal.NewTerminalPrinter().Println(*proxy.Proxy)

	return nil
}
