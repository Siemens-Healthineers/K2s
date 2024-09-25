// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package node

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/add"
	"github.com/spf13/cobra"
)

var NodeCmd = &cobra.Command{
	Use:   "node",
	Short: "[EXPERIMENTAL] Manage cluster nodes",
	Long:  "Add or Remove nodes to a k2s cluster",
}

func init() {
	NodeCmd.AddCommand(add.NodeAddCmd)
}
