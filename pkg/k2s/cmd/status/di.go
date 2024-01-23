// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"k2s/addons/print"
	"k2s/cmd/common"
	"k2s/cmd/status/json"
	"k2s/cmd/status/k8sversion"
	"k2s/cmd/status/load"
	"k2s/cmd/status/nodestatus"
	"k2s/cmd/status/podstatus"
	"k2s/cmd/status/runningstate"
	"k2s/cmd/status/setupinfo"
	"k2s/providers/marshalling"
	"k2s/providers/terminal"
)

func NewStatusPrinter() StatusPrinter {
	terminalPrinter := terminal.NewTerminalPrinter()
	runningStatePrinter := runningstate.NewRunningStatePrinter(terminalPrinter)
	setupInfoPrinter := setupinfo.NewSetupInfoPrinter(terminalPrinter, common.PrintNotInstalledMessage)
	addonsPrinter := print.NewAddonsPrinter(terminalPrinter)
	nodeStatusPrinter := nodestatus.NewNodeStatusPrinter(terminalPrinter)
	podStatusPrinter := podstatus.NewPodStatusPrinter(terminalPrinter)
	statusLoader := load.NewStatusLoader()
	k8sVersionPrinter := k8sversion.NewK8sVersionPrinter(terminalPrinter)

	return StatusPrinter{
		runningStatePrinter:   runningStatePrinter,
		terminalPrinter:       terminalPrinter,
		setupInfoPrinter:      setupInfoPrinter,
		addonsPrinter:         addonsPrinter,
		nodeStatusPrinter:     nodeStatusPrinter,
		podStatusPrinter:      podStatusPrinter,
		statusLoader:          statusLoader,
		k8sVersionInfoPrinter: k8sVersionPrinter,
	}
}

func NewStatusJsonPrinter() StatusJsonPrinter {
	jsonMarshaller := marshalling.NewJsonMarshaller()
	terminalPrinter := terminal.NewTerminalPrinter()

	return StatusJsonPrinter{
		statusLoader: load.NewStatusLoader(),
		jsonPrinter:  json.NewJsonPrinter(terminalPrinter, jsonMarshaller),
	}
}
