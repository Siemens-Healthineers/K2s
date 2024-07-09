// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	tagCommandExample = `
  # Tag image 'k2s-registry.local/myimage:v1' as 'k2s-registry.local/myimage:release'
  k2s image tag k2s-registry.local/myimage:v1 k2s-registry.local/myimage:release
`
	tagCmd = &cobra.Command{
		Use:     "tag",
		Short:   "Tag an image",
		Example: tagCommandExample,
		RunE:    tagImage,
	}
)

func init() {
	tagCmd.Flags().SortFlags = false
	tagCmd.Flags().PrintDefaults()
}

func tagImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Tagging container image..")

	err := validateTagArgs(args)
	if err != nil {
		return fmt.Errorf("invalid arguments provided: %w", err)
	}

	imageToTag := getImageToTag(args)
	newImageName := getNewImageName(args)

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	psCmd, params := buildTagPsCmd(imageToTag, newImageName, showOutput)

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), common.NewOutputWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image tag")

	return nil
}

func validateTagArgs(args []string) error {
	if len(args) != 2 {
		return errors.New("Please specify source image and new image name")
	}

	return nil
}

func getImageToTag(args []string) string {
	return args[0]
}

func getNewImageName(args []string) string {
	return args[1]
}

func buildTagPsCmd(imageToTag string, newImageName string, showOutput bool) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Tag-Image.ps1"))

	params = append(params, " -ImageName "+imageToTag)
	params = append(params, " -TargetImageName "+newImageName)

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
