// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package add

import (
	"github.com/spf13/cobra"
)

var NodeAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a node to the cluster",
	Long:  "Adds an machine or VM to an existing K2s cluster",
	RunE:  addNode,
}

const (
	MachineIPAddress          = "ip-addr"
	MachineIPAddressFlagUsage = "IP Address of the machine"
	MachineUsername           = "username"
	MachineUsernameFlagUsage  = "Username of the machine for remote connection"
)

func init() {
	NodeAddCmd.Flags().String(MachineIPAddress, "", MachineIPAddressFlagUsage)
	NodeAddCmd.Flags().String(MachineUsername, "", MachineUsernameFlagUsage)
	NodeAddCmd.Flags().SortFlags = false
	NodeAddCmd.Flags().PrintDefaults()
}

func addNode(cmd *cobra.Command, args []string) error {
	return nil
}
