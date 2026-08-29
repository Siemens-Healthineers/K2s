// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package version

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/common"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ve "github.com/siemens-healthineers/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var VersionCmd = &cobra.Command{
	Use:   cli.VersionFlagName,
	Short: cli.NewVersionFlagHint("K2s / k2s"),
	RunE:  showVersion,
}

func init() {
	VersionCmd.Flags().SortFlags = false
	VersionCmd.Flags().PrintDefaults()
}

func showVersion(ccmd *cobra.Command, args []string) error {
	ve.GetVersion().Print(common.CliName, pterm.Printf)
	return nil
}
