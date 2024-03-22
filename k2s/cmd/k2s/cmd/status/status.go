// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/load"
	si "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/setupinfo"

	sc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"

	"github.com/siemens-healthineers/k2s/internal/json"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

type RunningStatePrinter interface {
	PrintRunningState(runningState *sc.RunningState) (proceed bool, err error)
}

type NodeStatusPrinter interface {
	PrintNodeStatus(nodes []sc.Node, showAdditionalInfo bool) bool
}

type PodStatusPrinter interface {
	PrintPodStatus(pods []sc.Pod, showAdditionalInfo bool)
}

type SetupInfoPrinter interface {
	PrintSetupInfo(setupInfo *si.PrintSetupInfo) (proceed bool, err error)
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
	PrintJson(any) error
}

type K8sVersionInfoPrinter interface {
	PrintK8sVersionInfo(k8sVersionInfo *sc.K8sVersionInfo) error
}

type StatusPrinter struct {
	runningStatePrinter   RunningStatePrinter
	terminalPrinter       TerminalPrinter
	setupInfoPrinter      SetupInfoPrinter
	nodeStatusPrinter     NodeStatusPrinter
	podStatusPrinter      PodStatusPrinter
	k8sVersionInfoPrinter K8sVersionInfoPrinter
	loadStatusFunc        func(psVersion powershell.PowerShellVersion) (*load.LoadedStatus, error)
}

type StatusJsonPrinter struct {
	loadStatusFunc func(psVersion powershell.PowerShellVersion) (*load.LoadedStatus, error)
	jsonPrinter    JsonPrinter
}

type PrintStatus struct {
	SetupInfo      *si.PrintSetupInfo `json:"setupInfo"`
	RunningState   *sc.RunningState   `json:"runningState"`
	Nodes          []sc.Node          `json:"nodes"`
	Pods           []sc.Pod           `json:"pods"`
	K8sVersionInfo *sc.K8sVersionInfo `json:"k8sVersionInfo"`
	Error          *string            `json:"error"`
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

	terminalPrinter := terminal.NewTerminalPrinter()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return err
		}
		if outputOption == jsonOption {
			return printSystemNotInstalledErrJson(terminalPrinter.Println)
		}
		return common.CreateSystemNotInstalledCmdFailure()
	}

	psVersion := common.DeterminePsVersion(config)

	if outputOption == jsonOption {
		return printStatusAsJson(terminalPrinter, config, psVersion)
	}
	return printStatusUserFriendly(terminalPrinter, config, psVersion, outputOption == wideOption)
}

func printStatusAsJson(terminalPrinter terminal.TerminalPrinter, config *setupinfo.Config, psVersion powershell.PowerShellVersion) error {
	printer := NewStatusJsonPrinter(terminalPrinter)

	loadedStatus, err := printer.loadStatusFunc(psVersion)
	if err != nil {
		return err
	}

	printStatus := PrintStatus{
		SetupInfo:      toPrintInfo(config),
		RunningState:   loadedStatus.RunningState,
		Nodes:          loadedStatus.Nodes,
		Pods:           loadedStatus.Pods,
		K8sVersionInfo: loadedStatus.K8sVersionInfo,
	}

	var deferredErr error
	if loadedStatus.Failure != nil {
		printStatus.Error = &loadedStatus.Failure.Code
		loadedStatus.Failure.SuppressCliOutput = true
		deferredErr = loadedStatus.Failure
	}

	err = printer.jsonPrinter.PrintJson(printStatus)
	if err != nil {
		return fmt.Errorf("error occurred while printing status JSON: %w", errors.Join(deferredErr, err))
	}

	return deferredErr
}

func printSystemNotInstalledErrJson(printlnFunc func(m ...any)) error {
	errCode := setupinfo.ErrSystemNotInstalled.Error()
	printImages := PrintStatus{
		Error: &errCode,
	}

	bytes, err := json.MarshalIndent(printImages)
	if err != nil {
		return err
	}

	printlnFunc(string(bytes))

	failure := common.CreateSystemNotInstalledCmdFailure()
	failure.SuppressCliOutput = true

	return failure
}

func printStatusUserFriendly(terminalPrinter terminal.TerminalPrinter, config *setupinfo.Config, psVersion powershell.PowerShellVersion, showAdditionalInfo bool) error {
	printer := NewStatusPrinter(terminalPrinter)

	spinner, err := common.StartSpinner(terminalPrinter)
	if err != nil {
		return err
	}

	status, err := printer.loadStatusFunc(psVersion)

	common.StopSpinner(spinner)

	if err != nil {
		return fmt.Errorf("status could not be loaded: %w", err)
	}

	if status.Failure != nil {
		return status.Failure
	}

	printer.terminalPrinter.PrintHeader("K2s SYSTEM STATUS")

	proceed, err := printer.setupInfoPrinter.PrintSetupInfo(toPrintInfo(config))
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

	if config.SetupName == setupinfo.SetupNameBuildOnlyEnv {
		slog.Debug("Setup type has no K8s components, skipping", "type", setupinfo.SetupNameBuildOnlyEnv)
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

func toPrintInfo(config *setupinfo.Config) *si.PrintSetupInfo {
	return &si.PrintSetupInfo{
		Version:   config.Version,
		Name:      string(config.SetupName),
		LinuxOnly: config.LinuxOnly,
	}
}
