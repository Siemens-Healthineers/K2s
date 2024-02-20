// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"fmt"

	"k2s/cmd/common"
	"k2s/cmd/status/load"
	"k2s/setupinfo"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
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

type TerminalPrinter interface {
	Println(m ...any)
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
}

type Spinner interface {
	Stop() error
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
	nodeStatusPrinter     NodeStatusPrinter
	podStatusPrinter      PodStatusPrinter
	k8sVersionInfoPrinter K8sVersionInfoPrinter
	loadStatusFunc        func() (*load.Status, error)
}

type StatusJsonPrinter struct {
	loadStatusFunc func() (*load.Status, error)
	jsonPrinter    JsonPrinter
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

	var deferredErr error
	status, err := printer.loadStatusFunc()
	if err != nil {
		if !errors.Is(err, setupinfo.ErrNotInstalled) {
			return err
		}
		errMsg := setupinfo.ErrNotInstalledMsg
		status = &load.Status{SetupInfo: setupinfo.SetupInfo{Error: &errMsg}}

		deferredErr = errors.Join(err, common.ErrSilent)
	}

	printErr := printer.jsonPrinter.PrintJson(status)

	return errors.Join(deferredErr, printErr)
}

func printStatusUserFriendly(showAdditionalInfo bool) error {
	printer := NewStatusPrinter()

	startResult, err := printer.terminalPrinter.StartSpinner("Gathering status information...")
	if err != nil {
		return err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return errors.New("could not start operation")
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			klog.Error(err)
		}
	}()

	status, err := printer.loadStatusFunc()
	if err != nil {
		return fmt.Errorf("status could not be loaded: %w", err)
	}

	printer.terminalPrinter.PrintHeader("K2s SYSTEM STATUS")

	proceed, err := printer.setupInfoPrinter.PrintSetupInfo(status.SetupInfo)
	if err != nil {
		return err
	}
	if !proceed {
		return nil
	}

	proceed, err = printer.runningStatePrinter.PrintRunningState(status.RunningState)
	if err != nil {
		return err
	}
	if !proceed {
		return nil
	}

	if *status.SetupInfo.Name == setupinfo.SetupNameBuildOnlyEnv {
		klog.V(4).Infof("setup '%s' has no K8s components, skipping them", setupinfo.SetupNameBuildOnlyEnv)
		return nil
	}

	printer.terminalPrinter.Println()

	if err := printer.k8sVersionInfoPrinter.PrintK8sVersionInfo(status.K8sVersionInfo); err != nil {
		return err
	}

	proceed = printer.nodeStatusPrinter.PrintNodeStatus(status.Nodes, showAdditionalInfo)
	if !proceed {
		return nil
	}

	printer.podStatusPrinter.PrintPodStatus(status.Pods, showAdditionalInfo)

	return nil
}
