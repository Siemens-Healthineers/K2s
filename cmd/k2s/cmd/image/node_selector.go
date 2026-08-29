// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"strings"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

func addNodeSelectionFlags(cmd *cobra.Command) {
	cmd.Flags().String(nodeFlagName, "", "Node name to target (e.g. worker-1)")
	cmd.Flags().String(nodesFlagName, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
}

func parseNodeSelector(cmd *cobra.Command) (string, error) {
	nodesOption, err := cmd.Flags().GetString(nodesFlagName)
	if err != nil {
		return "", err
	}

	nodeOption, err := cmd.Flags().GetString(nodeFlagName)
	if err != nil {
		return "", err
	}

	nodeSelector := strings.TrimSpace(nodesOption)
	if nodeSelector == "" {
		nodeSelector = strings.TrimSpace(nodeOption)
	}

	return nodeSelector, nil
}

func appendNodesParam(params []string, nodes string) []string {
	if strings.TrimSpace(nodes) == "" {
		return params
	}

	return append(params, " -Nodes "+utils.EscapeWithSingleQuotes(nodes))
}
