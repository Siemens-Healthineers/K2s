// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package override

import (
	"path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/terminal"
	"github.com/spf13/cobra"
)

type ProxyOverrides struct {
	common.CmdResult
	ProxyOverrides []string `json:"proxyoverrides"`
}

var overrideListCmd = &cobra.Command{
	Use:   "ls",
	Short: "List all overrides",
	Long:  "List all overrides in the system",
	RunE:  listProxyOverrides,
}

func listProxyOverrides(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		return err
	}

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "override", "ListProxyOverrides.ps1"))
	var params []string
	proxy, err := powershell.ExecutePsWithStructuredResult[*ProxyOverrides](psCmd, "ProxyOverrides", common.DeterminePsVersion(config), common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	for _, v := range proxy.ProxyOverrides {
		terminal.NewTerminalPrinter().Println(v)
	}

	return nil
}
