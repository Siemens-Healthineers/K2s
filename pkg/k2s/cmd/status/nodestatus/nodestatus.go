// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package nodestatus

import (
	"k2s/cmd/status/common"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintSuccess(m ...any)
	PrintWarning(m ...any)
	PrintTableWithHeaders(table [][]string)
	PrintRedFg(text string) string
	PrintGreenFg(text string) string
}

type NodeStatusPrinter struct {
	terminalPrinter TerminalPrinter
}

func NewNodeStatusPrinter(printer TerminalPrinter) NodeStatusPrinter {
	return NodeStatusPrinter{terminalPrinter: printer}
}

func (n NodeStatusPrinter) PrintNodeStatus(nodes []common.Node, showAdditionalInfo bool) bool {
	headers := createHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allNodesReady := n.buildRows(nodes, showAdditionalInfo)

	table = append(table, rows...)

	n.terminalPrinter.PrintTableWithHeaders(table)

	if allNodesReady {
		n.terminalPrinter.PrintSuccess("All nodes are ready")
	} else {
		n.terminalPrinter.PrintWarning("Some nodes are not ready")
	}

	n.terminalPrinter.Println()

	return allNodesReady
}

func createHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "ROLE", "AGE", "VERSION"}

	if showAdditionalInfo {
		headers = append(headers, "INTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME")
	}

	return headers
}

func (n NodeStatusPrinter) buildRows(nodes []common.Node, showAdditionalInfo bool) ([][]string, bool) {
	allNodesReady := true
	var rows [][]string

	for _, node := range nodes {
		row := n.buildRow(node, showAdditionalInfo)
		if !node.IsReady {
			allNodesReady = false
		}

		rows = append(rows, row)
	}

	return rows, allNodesReady
}

func (n NodeStatusPrinter) buildRow(node common.Node, showAdditionalInfo bool) []string {
	status := n.getStatus(node)
	row := []string{status, node.Name, node.Role, node.Age, node.KubeletVersion}

	if showAdditionalInfo {
		row = append(row, node.InternalIp, node.OsImage, node.KernelVersion, node.ContainerRuntime)
	}

	return row
}

func (n NodeStatusPrinter) getStatus(node common.Node) string {
	if node.IsReady {
		return n.terminalPrinter.PrintGreenFg(node.Status)
	} else {
		return n.terminalPrinter.PrintRedFg(node.Status)
	}
}
