// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"
	"path"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/spf13/cobra"
)

var overrideDeleteCmd = &cobra.Command{
	Use:   "delete",
	Short: "Delete an override",
	RunE:  overrideDelete,
}

func overrideDelete(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	_, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if len(args) == 0 {
		return fmt.Errorf("incorrect number of arguments specified")
	}

	overrides := strings.Join(args, ",")

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "override", "DeleteProxyOverride.ps1"))
	psCmd += " -Overrides " + overrides

	var params []string

	result, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "ProxyOverrides", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if result != nil && result.Failure != nil {
		return result.Failure
	}

	return nil
}
