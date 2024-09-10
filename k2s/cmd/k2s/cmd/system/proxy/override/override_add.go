// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package override

import (
	"fmt"
	"path"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/spf13/cobra"
)

var overrideAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add an override",
	RunE:  overrideAdd,
}

func overrideAdd(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		return err
	}

	if len(args) == 0 {
		return fmt.Errorf("incorrect number of arguments specified")
	}

	overrides := strings.Join(args, ",")

	psCmd := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "override", "AddProxyOverride.ps1"))
	psCmd += " -Overrides " + overrides

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
