// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	listExample = `
	# List configured image registries in K2s 
	k2s image registry ls
`

	listCmd = &cobra.Command{
		Use:     "ls",
		Short:   "List configured registries",
		RunE:    listRegistries,
		Example: listExample,
	}
)

func init() {
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func listRegistries(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	registries := config.Registries

	if len(registries) == 0 {
		pterm.Println("No registries configured!")
		return nil
	}

	pterm.Printfln("Configured registries:")
	for _, v := range registries {
		pterm.Printfln("- %s", v)
	}

	return nil
}
