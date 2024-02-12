// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"fmt"
	"k2s/config"

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
	config := config.NewAccess()
	registries, err := config.GetConfiguredRegistries()
	if err != nil {
		return err
	}

	if len(registries) == 0 {
		pterm.Println("No registries configured!")
		return nil
	}

	pterm.Printfln("Configured registries:")
	for i, v := range registries {
		pterm.Printfln("%d. %s", (i + 1), v)
	}

	loggedInRegistry, err := config.GetLoggedInRegistry()
	if err != nil {
		return fmt.Errorf("error retrieving loggedInRegistry: %w", err)
	}

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
