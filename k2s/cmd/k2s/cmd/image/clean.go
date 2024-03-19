// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Remove container images from all nodes",
	RunE:  cleanImages,
}

func cleanImages(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Cleaning container images..")

	psCmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\helpers\\CleanImages.ps1")
	params := []string{}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{PowerShellVersion: powershell.DeterminePsVersion(config)}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image clean")

	return nil
}
