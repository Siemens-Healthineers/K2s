// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package network

import (
	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

const (
	networkStatusCommandExample = `
  # Networking status of the cluster
  k2s status network
`
)

var NetworkStatusCmd = &cobra.Command{
	Use:     "status",
	Short:   "Provides overview of K2s cluster networking in the installed machine",
	RunE:    printNetworkStatus,
	Example: networkStatusCommandExample,
}

func printNetworkStatus(cmd *cobra.Command, args []string) error {
	pterm.Printfln("Network status")
	return nil
}
