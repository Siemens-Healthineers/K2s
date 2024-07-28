// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package resultobserver

import (
	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
)

type PrettyLogObserver struct {
	ResultTable pterm.TableData
}

const statusRowNumber = 0

func NewPrettyLogObserver() *PrettyLogObserver {

	table := pterm.TableData{
		{"STATUS", "SOURCE POD", "TARGET POD", "TYPE", "ERR"},
	}

	return &PrettyLogObserver{ResultTable: table}
}

func (l *PrettyLogObserver) Update(result *networkchecker.NetworkCheckResult) {
	errStatus := resolveErrorMessage(result.Status, result.Error)
	status := determineColorStatus(result.Status)

	l.ResultTable = append(l.ResultTable, []string{status, result.SourcePod, result.TargetPod, string(result.CheckType), errStatus})

}

func (l *PrettyLogObserver) DumpSummary() {
	pterm.DefaultTable.WithHasHeader().WithBoxed().WithData(l.ResultTable).Render()

	allOk := true

	// Scan through the table rows (skipping header row)
	for _, row := range l.ResultTable[1:] {
		status := row[statusRowNumber]
		if status == determineColorStatus(networkchecker.StatusFail) {
			allOk = false
			break
		}
	}

	if allOk {
		pterm.Success.Printfln("All network checks are successful")
	} else {
		pterm.Warning.Printfln("Some network checks failed")
	}
}

// colorStatus colors the status based on its value
func determineColorStatus(status string) string {
	switch status {
	case networkchecker.StatusOK:
		return pterm.FgGreen.Sprint(status)
	case networkchecker.StatusFail:
		return pterm.FgRed.Sprint(status)
	default:
		return status
	}
}
