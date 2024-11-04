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

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	pushCommandExample = `
  # Push image 'myimage:v1' into 'k2s-registry.local' registry
  k2s image push -n k2s-registry.local/myimage:v1
  k2s image push --id 7ca25e0fabd39
`
	pushCmd = &cobra.Command{
		Use:     "push",
		Short:   "Push an image into a registry",
		Example: pushCommandExample,
		RunE:    pushImage,
	}
)

func init() {
	pushCmd.Flags().String(imageIdFlagName, "", "Image ID of the container image")
	pushCmd.Flags().StringP(imageNameFlagName, "n", "", "Name of the container image including tag")
	pushCmd.Flags().SortFlags = false
	pushCmd.Flags().PrintDefaults()
}

func pushImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Pushing container image..")

	err := validatePushArgs(args)
	if err != nil {
		return fmt.Errorf("invalid arguments provided: %w", err)
	}

	psCmd, params, err := buildPushPsCmd(cmd)

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

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
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

	common.PrintCompletedMessage(duration, "image push")

	return nil
}

func validatePushArgs(args []string) error {
	if len(args) == 0 {
		return errors.New("no image to push")
	}

	if len(args) > 1 {
		return errors.New("more than 1 image to push. Can only push 1 image at a time")
	}

	return nil
}

func buildPushPsCmd(cmd *cobra.Command) (psCmd string, params []string, err error) {

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", imageNameFlagName, err)
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Push-Image.ps1"))

	if imageId != "" {
		params = append(params, " -Id "+imageId)
	}
	if imageName != "" {
		params = append(params, " -ImageName "+imageName)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
