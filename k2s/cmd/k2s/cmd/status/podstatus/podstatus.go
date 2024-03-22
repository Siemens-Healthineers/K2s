// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package podstatus

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"

	a "github.com/siemens-healthineers/k2s/internal/primitives/arrays"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintSuccess(m ...any)
	PrintWarning(m ...any)
	PrintTableWithHeaders(table [][]string)
	PrintRedFg(text string) string
	PrintGreenFg(text string) string
}

type PodStatusPrinter struct {
	terminalPrinter TerminalPrinter
}

func NewPodStatusPrinter(printer TerminalPrinter) PodStatusPrinter {
	return PodStatusPrinter{terminalPrinter: printer}
}

func (p PodStatusPrinter) PrintPodStatus(pods []common.Pod, showAdditionalInfo bool) {

	headers := createHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allPodsRunning := p.buildRows(pods, showAdditionalInfo)

	table = append(table, rows...)

	p.terminalPrinter.PrintTableWithHeaders(table)

	if allPodsRunning {
		p.terminalPrinter.PrintSuccess("All essential Pods are running")
	} else {
		p.terminalPrinter.PrintWarning("Some essential Pods are not running")
	}

	p.terminalPrinter.Println()
}

func createHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "READY", "RESTARTS", "AGE"}

	if showAdditionalInfo {
		headers = a.Insert(headers, "NAMESPACE", 1)
		headers = append(headers, "IP", "NODE")
	}

	return headers
}

func (p PodStatusPrinter) buildRows(pods []common.Pod, showAdditionalInfo bool) ([][]string, bool) {
	allPodsRunning := true
	var rows [][]string

	for _, pod := range pods {
		row := p.buildRow(pod, showAdditionalInfo)
		if !pod.IsRunning {
			allPodsRunning = false
		}

		rows = append(rows, row)
	}

	return rows, allPodsRunning
}

func (p PodStatusPrinter) buildRow(pod common.Pod, showAdditionalInfo bool) []string {
	state := p.getStatusInfo(pod)

	row := []string{state, pod.Name, pod.Ready, pod.Restarts, pod.Age}

	if showAdditionalInfo {
		row = a.Insert(row, pod.Namespace, 1)
		row = append(row, pod.Ip, pod.Node)
	}

	return row
}

func (p PodStatusPrinter) getStatusInfo(pod common.Pod) string {
	if pod.IsRunning {
		return p.terminalPrinter.PrintGreenFg("Running")
	} else {
		return p.terminalPrinter.PrintRedFg(pod.Status)
	}
}
