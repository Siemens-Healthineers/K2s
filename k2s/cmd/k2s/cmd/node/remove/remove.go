// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package remove

import (
	"github.com/spf13/cobra"
)

var NodeRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove a node from the cluster",
	Long:  "Removes machine or VM from K2s cluster",
	RunE:  removeNode,
}

const (
	MachineName          = "name"
	MachineNameFlagUsage = "Hostname of the machine"
)

func init() {
	NodeRemoveCmd.Flags().String(MachineName, "", MachineNameFlagUsage)
	NodeRemoveCmd.MarkFlagsOneRequired(MachineName)

	NodeRemoveCmd.Flags().SortFlags = false
	NodeRemoveCmd.Flags().PrintDefaults()

}

func removeNode(cmd *cobra.Command, args []string) error {
	return nil
}
