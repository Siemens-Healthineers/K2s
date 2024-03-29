// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type removeOptions struct {
	imageId      string
	imageName    string
	fromRegistry bool
	showOutput   bool
}

var (
	imageIdFlagName       = "id"
	removeImgNameFlagName = "name"
	fromRegistryFlagName  = "from-registry"

	removeExample = `
  # Delete image by id
  k2s image rm --id 042a816809aa

  # Delete pushed image from registry
  k2s image rm --name k2s-registry.local/alpine:v1 --from-registry
`

	removeCmd = &cobra.Command{
		Use:     "rm",
		Short:   "Remove container image using image id or image name",
		Example: removeExample,
		RunE:    removeImage,
	}
)

func init() {
	addInitFlagsForRemoveCommand(removeCmd)
}

func addInitFlagsForRemoveCommand(cmd *cobra.Command) {
	cmd.Flags().String(imageIdFlagName, "", "Image ID of the container image")
	cmd.Flags().String(removeImgNameFlagName, "", "Name of the container image")
	cmd.Flags().Bool(fromRegistryFlagName, false, "Remove image from registry")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func removeImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Removing container image..")

	options, err := extractRemoveOptions(cmd)
	if err != nil {
		return err
	}

	psCmd, params := buildRemovePsCmd(options)

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

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), outputWriter, params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image rm")

	return nil
}

func extractRemoveOptions(cmd *cobra.Command) (*removeOptions, error) {
	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(removeImgNameFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", removeImgNameFlagName, err)
	}

	fromRegistry, err := strconv.ParseBool(cmd.Flags().Lookup(fromRegistryFlagName).Value.String())
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", fromRegistryFlagName, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(params.OutputFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	return &removeOptions{
		imageId:      imageId,
		imageName:    imageName,
		fromRegistry: fromRegistry,
		showOutput:   showOutput,
	}, nil
}

func buildRemovePsCmd(removeOptions *removeOptions) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\helpers\\RemoveImage.ps1")

	if removeOptions.imageId != "" {
		params = append(params, " -ImageId "+removeOptions.imageId)
	}
	if removeOptions.imageName != "" {
		params = append(params, " -ImageName "+removeOptions.imageName)
	}
	if removeOptions.fromRegistry {
		params = append(params, " -FromRegistry")
	}
	if removeOptions.showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
