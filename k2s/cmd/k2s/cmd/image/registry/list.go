// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/terminal"

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
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	registries := runtimeConfig.ClusterConfig().Registries()

	terminalPrinter := terminal.NewTerminalPrinter()

	if len(registries) == 0 {
		terminalPrinter.PrintInfoln("No registries configured!")
		return nil
	}

	terminalPrinter.PrintHeader("Configured registries:")
	for _, v := range registries {
		terminalPrinter.Printfln(" - %s", v)
	}

	return nil
}
