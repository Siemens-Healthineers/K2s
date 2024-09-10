// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"os"
	"slices"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/export"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/generic"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/importcmd"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/list"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/core/addons"

	"github.com/spf13/cobra"
)

func NewCmd() (*cobra.Command, error) {
	var cmd = &cobra.Command{
		Use:   "addons",
		Short: "Manage addons",
		Long:  "Addons add optional functionality to a K8s cluster",
	}

	cmd.AddCommand(importcmd.NewCommand())
	cmd.AddCommand(export.NewCommand())

	if !slices.Contains(os.Args, cmd.Use) {
		return cmd, nil
	}

	addons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return nil, err
	}

	// TODO: create generic commands for all addons
	cmd.AddCommand(list.NewCommand(addons))
	cmd.AddCommand(status.NewCommand(addons))

	commands, err := generic.NewCommands(addons)
	if err != nil {
		return nil, err
	}

	cmd.AddCommand(commands...)

	return cmd, nil
}
