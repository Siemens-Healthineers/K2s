// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/json"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/k8sversion"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/load"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/nodestatus"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/podstatus"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/setupinfo"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/runningstate"

	"github.com/siemens-healthineers/k2s/internal/providers/terminal"

	"github.com/siemens-healthineers/k2s/internal/providers/marshalling"
)

func NewStatusPrinter() StatusPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()
	runningStatePrinter := runningstate.NewRunningStatePrinter(terminalPrinter)
	setupInfoPrinter := setupinfo.NewSetupInfoPrinter(terminalPrinter)
	nodeStatusPrinter := nodestatus.NewNodeStatusPrinter(terminalPrinter)
	podStatusPrinter := podstatus.NewPodStatusPrinter(terminalPrinter)
	k8sVersionPrinter := k8sversion.NewK8sVersionPrinter(terminalPrinter)

	return StatusPrinter{
		runningStatePrinter:   runningStatePrinter,
		terminalPrinter:       terminalPrinter,
		setupInfoPrinter:      setupInfoPrinter,
		nodeStatusPrinter:     nodeStatusPrinter,
		podStatusPrinter:      podStatusPrinter,
		loadStatusFunc:        load.LoadStatus,
		k8sVersionInfoPrinter: k8sVersionPrinter,
	}
}

func NewStatusJsonPrinter() StatusJsonPrinter {
	jsonMarshaller := marshalling.NewJsonMarshaller()
	terminalPrinter := terminal.NewTerminalPrinter()

	return StatusJsonPrinter{
		loadStatusFunc: load.LoadStatus,
		jsonPrinter:    json.NewJsonPrinter(terminalPrinter, jsonMarshaller),
	}
}