// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/provider"
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Remove container images from all nodes",
	RunE:  cleanImages,
}

func cleanImages(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Cleaning container images..")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	if err := context.Providers().Image.Clean(provider.ImageCleanConfig{
		ShowOutput: showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
