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
	targetImageNameFlagName = "target-name"
	tagCommandExample       = `
  # Tag image 'k2s.registry.local/myimage:v1' as 'k2s.registry.local/myimage:release'
  k2s image tag -n k2s.registry.local/myimage:v1 -t k2s.registry.local/myimage:release
  k2s image tag --id 7ca25e0fabd39 -t k2s.registry.local/myimage:release
`
	tagCmd = &cobra.Command{
		Use:     "tag",
		Short:   "Tag an image",
		Example: tagCommandExample,
		RunE:    tagImage,
	}
)

func init() {
	tagCmd.Flags().String(imageIdFlagName, "", "Image ID of the container image")
	tagCmd.Flags().StringP(imageNameFlagName, "n", "", "Name of the container image including tag")
	tagCmd.Flags().StringP(targetImageNameFlagName, "t", "", "New name of the container image including tag")
	tagCmd.Flags().SortFlags = false
	tagCmd.Flags().PrintDefaults()
}

func tagImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Tagging container image..")

	psCmd, params, err := buildTagPsCmd(cmd)
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

	common.PrintCompletedMessage(duration, "image tag")

	return nil
}

func buildTagPsCmd(cmd *cobra.Command) (psCmd string, params []string, err error) {

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", imageNameFlagName, err)
	}

	targetImageName, err := cmd.Flags().GetString(targetImageNameFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", targetImageNameFlagName, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if imageId == "" && imageName == "" {
		return "", nil, errors.New("no image id or image name provided")
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Tag-Image.ps1"))

	if imageId != "" {
		params = append(params, " -Id "+imageId)
	}
	if imageName != "" {
		params = append(params, " -ImageName "+imageName)
	}
	if targetImageName != "" {
		params = append(params, " -TargetImageName "+targetImageName)
	}
	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
