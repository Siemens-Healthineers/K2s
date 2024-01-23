// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"fmt"

	"k2s/addons"
	"k2s/addons/print"
	"k2s/cmd/status/load"
	"k2s/setupinfo"

	"github.com/spf13/cobra"
)

type RunningStatePrinter interface {
	PrintRunningState(runningState *load.RunningState) (proceed bool, err error)
}

type NodeStatusPrinter interface {
	PrintNodeStatus(nodes []load.Node, showAdditionalInfo bool) bool
}

type PodStatusPrinter interface {
	PrintPodStatus(pods []load.Pod, showAdditionalInfo bool)
}

type SetupInfoPrinter interface {
	PrintSetupInfo(setupinfo.SetupInfo) (proceed bool, err error)
}

type AddonsPrinter interface {
	PrintAddons(enabledAddons []string, addons []print.AddonPrintInfo) error
}

type TerminalPrinter interface {
	Println(m ...any)
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
}

type Spinner interface {
	Stop() error
	Success(m ...any)
	Fail(m ...any)
}

type StatusLoader interface {
	LoadStatus() (*load.Status, error)
}

type JsonPrinter interface {
	PrintJson(*load.Status) error
}

type K8sVersionInfoPrinter interface {
	PrintK8sVersionInfo(k8sVersionInfo *load.K8sVersionInfo) error
}

type StatusPrinter struct {
	runningStatePrinter   RunningStatePrinter
	terminalPrinter       TerminalPrinter
	setupInfoPrinter      SetupInfoPrinter
	addonsPrinter         AddonsPrinter
	nodeStatusPrinter     NodeStatusPrinter
	podStatusPrinter      PodStatusPrinter
	statusLoader          StatusLoader
	k8sVersionInfoPrinter K8sVersionInfoPrinter
}

type StatusJsonPrinter struct {
	statusLoader StatusLoader
	jsonPrinter  JsonPrinter
}

const (
	outputFlagName = "output"
	wideOption     = "wide"
	jsonOption     = "json"
)

const statusCommandExample = `
  # Status of the cluster
  k2s status

  # Status of the cluster with more information
  k2s status -o wide

  # Status of the cluster in JSON output format
  k2s status -o json
`

var StatusCmd = &cobra.Command{
	Use:     "status",
	Short:   "Prints out status information about the K2s cluster on this machine",
	RunE:    printStatus,
	Example: statusCommandExample,
}

func init() {
	StatusCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'wide' for more information and 'json' for output as JSON structure")
	StatusCmd.Flags().SortFlags = false
	StatusCmd.Flags().PrintDefaults()
}

func printStatus(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != wideOption && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	if outputOption == jsonOption {
		if err := printStatusAsJson(); err != nil {
			return err
		}
		return nil
	}
	return printStatusUserFriendly(outputOption == wideOption)
}

func printStatusAsJson() error {
	printer := NewStatusJsonPrinter()

	status, err := printer.statusLoader.LoadStatus()
	if err != nil {
		return err
	}

	return printer.jsonPrinter.PrintJson(status)
}

func printStatusUserFriendly(showAdditionalInfo bool) error {
	printer := NewStatusPrinter()

	printer.terminalPrinter.PrintHeader("K2s CLUSTER STATUS")

	startResult, err := printer.terminalPrinter.StartSpinner("Gathering status information...")
	if err != nil {
		return err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return errors.New("could not start operation")
	}

	status, err := printer.statusLoader.LoadStatus()
	if err != nil {
		spinner.Fail("Status could not be loaded")
		return err
	}

	proceed, err := printer.setupInfoPrinter.PrintSetupInfo(status.SetupInfo)
	if err != nil {
		spinner.Fail("Setup info could not be printed")
		return err
	}

	if !proceed {
		return nil
	}

	if err := printer.addonsPrinter.PrintAddons(status.EnabledAddons, addons.AllAddons().ToPrintInfo()); err != nil {
		return err
	}

	proceed, err = printer.runningStatePrinter.PrintRunningState(status.RunningState)
	if err != nil {
		spinner.Fail("Running state could not be printed")
		return err
	}

	if !proceed {
		if err := spinner.Stop(); err != nil {
			return err
		}
		return nil
	}

	printer.terminalPrinter.Println()

	if err := printer.k8sVersionInfoPrinter.PrintK8sVersionInfo(status.K8sVersionInfo); err != nil {
		spinner.Fail("K8s version info could not be printed")
		return err
	}

	if err := spinner.Stop(); err != nil {
		return err
	}

	proceed = printer.nodeStatusPrinter.PrintNodeStatus(status.Nodes, showAdditionalInfo)
	if !proceed {
		return nil
	}

	printer.podStatusPrinter.PrintPodStatus(status.Pods, showAdditionalInfo)

	return nil
}
