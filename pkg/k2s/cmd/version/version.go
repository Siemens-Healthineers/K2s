// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package version

import (
	ve "base/version"
	cm "k2s/cmd/common"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var VersionCmd = &cobra.Command{
	Use:   "version",
	Short: "Shows the current version of the k2s",
	RunE:  showVersion,
}

func init() {
	VersionCmd.Flags().SortFlags = false
	VersionCmd.Flags().PrintDefaults()
}

func showVersion(ccmd *cobra.Command, args []string) error {
	version := ve.GetVersion()
	pterm.Printf("%s: %s\n", cm.CliName, version)

	pterm.Printf("  BuildDate: %s\n", version.BuildDate)
	pterm.Printf("  GitCommit: %s\n", version.GitCommit)
	pterm.Printf("  GitTreeState: %s\n", version.GitTreeState)
	if version.GitTag != "" {
		pterm.Printf("  GitTag: %s\n", version.GitTag)
	}
	pterm.Printf("  GoVersion: %s\n", version.GoVersion)
	pterm.Printf("  Compiler: %s\n", version.Compiler)
	pterm.Printf("  Platform: %s\n", version.Platform)

	return nil
}
