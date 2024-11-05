// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package remove

import (
	"github.com/spf13/cobra"
)

const (
	MachineName          = "name"
	MachineNameFlagUsage = "Hostname of the machine"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "remove",
		Short: "[EXPERIMENTAL] Remove a node from the cluster",
		Long:  "Removes machine or VM from K2s cluster",
		RunE:  removeNode,
	}
	cmd.Flags().String(MachineName, "", MachineNameFlagUsage)
	cmd.MarkFlagsOneRequired(MachineName)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func removeNode(cmd *cobra.Command, args []string) error {
	return nil
}
