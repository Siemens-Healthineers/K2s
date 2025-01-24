// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"fmt"
	"path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/spf13/cobra"
)

var proxyResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset the proxy settings",
	Long:  "This command resets the proxy settings to their default values.",
	RunE:  resetProxyConfig,
}

func resetProxyConfig(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host().K2sConfigDir())
	if err != nil {
		return err
	}

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "ResetProxy.ps1"))
	var params []string

	result, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "ProxyOverrides", common.DeterminePsVersion(config), common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if result.Failure != nil {
		return fmt.Errorf(result.Failure.Error())
	}

	return nil
}
