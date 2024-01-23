// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"fmt"
	"k2s/cmd/common"
	"k2s/config"
	"k2s/config/defs"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var listExample = `
	# List configured image registries in K2s 
	k2s image registry ls
`

var listCmd = &cobra.Command{
	Use:     "ls",
	Short:   "List configured registries",
	RunE:    listRegistries,
	Example: listExample,
}

func init() {
	includeAddCommand(listCmd)
}

func listRegistries(cmd *cobra.Command, args []string) error {
	config := config.NewAccess()
	registries, err := config.GetConfiguredRegisties()
	switch err {
	case nil:
		break
	case defs.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
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
		return fmt.Errorf("error retrieving loggedInRegistry: %s", err)
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
