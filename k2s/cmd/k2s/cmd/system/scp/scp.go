// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package scp

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/spf13/cobra"
)

const (
	sourceFlag  = "source"
	targetFlag  = "target"
	reverseFlag = "reverse"

	mReverseShort = "Copy from KubeMaster to local machine"
	wReverseShort = "Copy from WinNode VM to local machine"

	mShort = "Copy from local machine to KubeMaster"
	wShort = "Copy from local machine to WinNode VM in multi-vm setup"

	scriptRelPathToScpMaster = "\\lib\\scripts\\k2s\\system\\scp\\scpm.ps1"
	scriptRelPathToScpWorker = "\\lib\\scripts\\multivm\\system\\scp\\scpw.ps1"

	mExample = `
  # Copy a yaml manifest from local machine to KubeMaster
  k2s system scp m C:\tmp\manifest.yaml /tmp

  # Copy a yaml manifest from KubeMaster to local machine
  k2s system scp m /tmp/manifest.yaml C:\tmp\ -r
`
	wExample = `
  # Copy a yaml manifest from local machine to WinNode VM in multi-vm setup
  k2s system scp w C:\tmp\manifest.yaml C:\tmp\worker\manifest.yaml

  # Copy a yaml manifest from WinNode VM to local machine in multi-vm setup
  k2s system scp w C:\tmp\worker\manifest.yaml C:\tmp\manifest.yaml -r
`
)

var ScpCmd = &cobra.Command{
	Use:   "scp",
	Short: "Copies sources via scp from/to a specific VM",
}

func init() {
	ScpCmd.AddCommand(buildScpSubCmd("m", mShort, mExample, scriptRelPathToScpMaster, mReverseShort))
	ScpCmd.AddCommand(buildScpSubCmd("w", wShort, wExample, scriptRelPathToScpWorker, wReverseShort))
}

func buildScpSubCmd(useShort, short, example, scriptPath, reverseShort string) *cobra.Command {
	cmd := &cobra.Command{
		Use:     fmt.Sprintf("%s SOURCE TARGET", useShort),
		Short:   short,
		Example: example,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runScpCmd(cmd, args, scriptPath)
		},
	}

	cmd.Flags().BoolP(reverseFlag, "r", false, fmt.Sprintf("Reverse direction: %s", reverseShort))
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runScpCmd(cmd *cobra.Command, args []string, scriptPath string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no source path specified")
	}

	if args[1] == "" {
		return errors.New("no target path specified")
	}

	psCmd, params, err := buildScpPsCmd(cmd, args, scriptPath)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	// TODO: disable copying to/from worker node for multivm
	if config.SetupName == setupinfo.SetupNameMultiVMK8s && scriptPath == scriptRelPathToScpWorker {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, fmt.Sprintf("%s %s", ScpCmd.Use, cmd.Use))

	return nil
}

func buildScpPsCmd(cmd *cobra.Command, args []string, scriptPath string) (psCmd string, params []string, err error) {
	reverse, err := strconv.ParseBool(cmd.Flags().Lookup(reverseFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + scriptPath)

	params = append(params, " -Source "+utils.EscapeWithSingleQuotes(args[0]), " -Target "+utils.EscapeWithSingleQuotes(args[1]))

	if reverse {
		params = append(params, " -Reverse")
	}

	return
}
