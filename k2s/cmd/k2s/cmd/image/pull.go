// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/cmd/k2s/setupinfo"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

const (
	pullForWindowsFlag          = "windows"
	pullForWindowsFlagShorthand = "w"
	pullForWindowsDefault       = false
	pullForWindowsFlagDesc      = "Pull image on Windows node"
)

var (
	pullCommandExample = `
  # Pull a Linux image onto the Linux node
  k2s image pull nginx:latest

  # Pull a Windows image onto a Windows 10 node
  k2s image pull mcr.microsoft.com/windows:20H2 --windows 
  OR
  k2s image pull mcr.microsoft.com/windows:20H2 -w
`
	pullCmd = &cobra.Command{
		Use:     "pull",
		Short:   "Pull an image onto a Kubernetes node",
		Example: pullCommandExample,
		RunE:    pullImage,
	}
)

func init() {
	pullCmd.Flags().BoolP(pullForWindowsFlag, pullForWindowsFlagShorthand, pullForWindowsDefault, pullForWindowsFlagDesc)
	pullCmd.Flags().SortFlags = false
	pullCmd.Flags().PrintDefaults()
}

func pullImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Pulling container image..")

	err := validateArgs(args)
	if err != nil {
		return fmt.Errorf("invalid arguments provided: %w", err)
	}

	imageToPull := getImageToPull(args)

	pullForWindows, err := strconv.ParseBool(cmd.Flags().Lookup(pullForWindowsFlag).Value.String())
	if err != nil {
		return err
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	psCmd, params := buildPullPsCmd(imageToPull, pullForWindows, showOutput)

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image pull")

	return nil
}

func validateArgs(args []string) error {
	if len(args) == 0 {
		return errors.New("no image to pull")
	}

	if len(args) > 1 {
		return errors.New("more than 1 image to pull. Can only pull 1 image at a time")
	}

	return nil
}

func getImageToPull(args []string) string {
	return args[0]
}

func buildPullPsCmd(imageToPull string, pullForWindows bool, showOutput bool) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\PullImage.ps1")

	params = append(params, " -ImageName "+imageToPull)

	if pullForWindows {
		params = append(params, " -Windows")
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}