// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"

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
	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
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
	for i, v := range registries {
		pterm.Printfln("%d. %s", (i + 1), v)
	}

	loggedInRegistry := config.LoggedInRegistry

	if loggedInRegistry == "" {
		pterm.Printfln("")
		pterm.Printfln("Currently you are not logged in into a configured registry.")
		pterm.Printfln("In order to login into configured registry, call 'k2s image registry switch <registry>'")
	} else {
		pterm.Printfln("")
		pterm.Printfln("Currently you are logged in into configured registry:")
		pterm.Printfln("%s", loggedInRegistry)
	}

	return nil
}
