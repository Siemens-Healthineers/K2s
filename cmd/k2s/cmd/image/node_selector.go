// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
)

const (
	nodeFlagName  = "node"
	nodesFlagName = "nodes"
)

func addNodeSelectionFlags(cmd *cobra.Command) {
	cmd.Flags().String(nodeFlagName, "", "Node name to target (e.g. worker-1)")
	cmd.Flags().String(nodesFlagName, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
}

func parseNodeSelector(cmd *cobra.Command) (string, error) {
	return common.ParseNodeSelector(cmd, nodeFlagName, nodesFlagName)
}

func appendNodesParam(params []string, nodes string) []string {
	return common.AppendNodesParam(params, nodes)
}
