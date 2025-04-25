// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package scp

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

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

	mShort = "Copy from local machine to KubeMaster"

	scriptRelPathToScpMaster = "\\lib\\scripts\\k2s\\system\\scp\\scpm.ps1"

	mExample = `
  # Copy a yaml manifest from local machine to KubeMaster
  k2s system scp m C:\tmp\manifest.yaml /tmp

  # Copy a yaml manifest from KubeMaster to local machine
  k2s system scp m /tmp/manifest.yaml C:\tmp\ -r
`
)

var ScpCmd = &cobra.Command{
	Use:   "scp",
	Short: "Copies sources via scp from/to a specific VM",
}

func init() {
	ScpCmd.AddCommand(buildScpSubCmd("m", mShort, mExample, scriptRelPathToScpMaster, mReverseShort))
}

func buildScpSubCmd(useShort, short, example, scriptPath, reverseShort string) *cobra.Command {
	cmd := &cobra.Command{
		Use:     fmt.Sprintf("%s SOURCE TARGET", useShort),
		Short:   short,
		Example: example,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runScpCmd(cmd, args, scriptPath)
		},
		Deprecated: "This command is deprecated and will be removed in the future. Use 'k2s node copy' instead.", // TODO: fulfill promise
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

	cmdSession := common.StartCmdSession(cmd.CommandPath())
	psCmd, params, err := buildScpPsCmd(cmd, args, scriptPath)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	_, err = setupinfo.ReadConfig(context.Config().Host().K2sConfigDir())
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

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
