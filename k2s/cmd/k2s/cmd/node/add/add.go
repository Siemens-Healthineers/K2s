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
	MachineName               = "name"
	MachineNameFlagUsage      = "Hostname of the machine"
	MachineIPAddress          = "ip-addr"
	MachineIPAddressFlagUsage = "IP Address of the machine"
	MachineUsername           = "username"
	MachineUsernameFlagUsage  = "Username of the machine for remote connection"
	MachineRole               = "role"
	MachineRoleFlagUsage      = "Role of the machine as a node"
)

func init() {
	NodeAddCmd.Flags().String(MachineIPAddress, "", MachineIPAddressFlagUsage)
	NodeAddCmd.Flags().String(MachineUsername, "", MachineUsernameFlagUsage)
	NodeAddCmd.Flags().String(MachineName, "", MachineNameFlagUsage)
	NodeAddCmd.Flags().String(MachineRole, "worker", MachineRoleFlagUsage)

	NodeAddCmd.MarkFlagsRequiredTogether(MachineIPAddress, MachineUsername)

	NodeAddCmd.Flags().SortFlags = false
	NodeAddCmd.Flags().PrintDefaults()
}

func addNode(cmd *cobra.Command, args []string) error {
	return nil
}
