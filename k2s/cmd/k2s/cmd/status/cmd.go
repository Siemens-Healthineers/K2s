// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"fmt"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/json"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

type StatusPrinter interface {
	Print() error
}

const (
	outputFlagName = "output"
	wideOption     = "wide"
	jsonOption     = "json"

	statusCommandExample = `
  # Status of the cluster
  k2s status

  # Status of the cluster with more information
  k2s status -o wide

  # Status of the cluster in JSON output format
  k2s status -o json
`
)

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

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			if outputOption == jsonOption {
				return printSystemErrJson(terminalPrinter.Println, setupinfo.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)
			}
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			if outputOption == jsonOption {
				return printSystemErrJson(terminalPrinter.Println, setupinfo.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)
			}
			return common.CreateSystemNotInstalledCmdFailure()
		}

		return err
	}

	printer := determinePrinter(outputOption, config, terminalPrinter)

	return printer.Print()
}

func determinePrinter(outputOption string, config *setupinfo.Config, terminalPrinter TerminalPrinter) StatusPrinter {
	psVersion := common.DeterminePsVersion(config)
	loadFunc := func() (*LoadedStatus, error) {
		return LoadStatus(psVersion)
	}

	if outputOption == jsonOption {
		return NewJsonPrinter(config, terminalPrinter.Println, json.MarshalIndent, loadFunc)
	}
	return NewUserFriendlyPrinter(config, outputOption == wideOption, terminalPrinter, loadFunc)
}

func printSystemErrJson(printlnFunc func(m ...any), systemError error, systemCmdFailureFunc func() *common.CmdFailure) error {
	errCode := systemError.Error()
	status := PrintStatus{
		Error: &errCode,
	}

	bytes, err := json.MarshalIndent(status)
	if err != nil {
		return err
	}

	printlnFunc(string(bytes))

	failure := systemCmdFailureFunc()
	failure.SuppressCliOutput = true

	return failure
}
