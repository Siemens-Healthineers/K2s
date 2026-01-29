// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type removeOptions struct {
	imageId      string
	imageName    string
	fromRegistry bool
	force        bool
	showOutput   bool
}

var (
	imageIdFlagName       = "id"
	removeImgNameFlagName = "name"
	fromRegistryFlagName  = "from-registry"
	forceFlagName         = "force"

	removeExample = `
  # Delete image by id
  k2s image rm --id 042a816809aa

  # Delete pushed image from local registry
  k2s image rm --name k2s.registry.local/alpine:v1 --from-registry
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
	cmd.Flags().Bool(fromRegistryFlagName, false, "Remove image from local registry (when registry addon is enabled)")
	cmd.Flags().Bool(forceFlagName, false, "Force removal by first removing any containers using the image")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func removeImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Removing container image..")

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
	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	options, err := extractRemoveOptions(cmd)
	if err != nil {
		return err
	}

	psCmd, params := buildRemovePsCmd(options)

	slog.Debug("PS command created", "command", psCmd, "params", params)

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

	force, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlagName).Value.String())
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", forceFlagName, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	return &removeOptions{
		imageId:      imageId,
		imageName:    imageName,
		fromRegistry: fromRegistry,
		force:        force,
		showOutput:   showOutput,
	}, nil
}

func buildRemovePsCmd(removeOptions *removeOptions) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Remove-Image.ps1"))

	if removeOptions.imageId != "" {
		params = append(params, " -ImageId "+removeOptions.imageId)
	}
	if removeOptions.imageName != "" {
		params = append(params, " -ImageName "+removeOptions.imageName)
	}
	if removeOptions.fromRegistry {
		params = append(params, " -FromRegistry")
	}
	if removeOptions.force {
		params = append(params, " -Force")
	}
	if removeOptions.showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
