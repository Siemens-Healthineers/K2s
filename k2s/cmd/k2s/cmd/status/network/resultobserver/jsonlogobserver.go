// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package resultobserver

import (
	"log"

	"github.com/siemens-healthineers/k2s/internal/json"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
)

type PrintNetworkResult struct {
	Results []PrintNetworkResultItem `json:"results"`
	AllOkay bool                     `json:"allcheckspassed"`
}

type PrintNetworkResultItem struct {
	Status    *string `json:"status"`
	SourcePod *string `json:"sourcepod"`
	TargetPod *string `json:"targetpod"`
	CheckType *string `json:"type"`
	Error     *string `json:"error"`
}

type JSONLogObserver struct {
	printNetworkResult *PrintNetworkResult
}

func NewJSONLogObserver() *JSONLogObserver {
	return &JSONLogObserver{
		printNetworkResult: &PrintNetworkResult{},
	}
}

func (l *JSONLogObserver) Update(result *networkchecker.NetworkCheckResult) {

	cleanedErrorMsg := resolveErrorMessage(result.Status, result.Error)
	printNetworkResultItem := PrintNetworkResultItem{Status: &result.Status,
		SourcePod: &result.SourcePod,
		TargetPod: &result.TargetPod,
		CheckType: (*string)(&result.CheckType),
		Error:     &cleanedErrorMsg}

	l.printNetworkResult.Results = append(l.printNetworkResult.Results, printNetworkResultItem)
}

func (l *JSONLogObserver) DumpSummary() {
	allOk := true

	for _, row := range l.printNetworkResult.Results {
		if *row.Status == networkchecker.StatusFail {
			allOk = false
			break
		}
	}

	finalRawJsonContent := PrintNetworkResult{
		Results: l.printNetworkResult.Results,
		AllOkay: allOk,
	}

	bytes, err := json.MarshalIndent(finalRawJsonContent)
	if err != nil {
		log.Fatalf("Failed to marshal results: %v", err)
	}
	pterm.Println(string(bytes))
}
