// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/provider"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	pushCommandExample = `
  # Push image to registry; image is looked up on default nodes (Linux control-plane and local Windows host)
  k2s image push -n k2s.registry.local/myimage:v1
  k2s image push --id 7ca25e0fabd39

  # Push image that resides on a specific worker node
  k2s image push -n k2s.registry.local/myimage:v1 --node worker-1

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
	addNodeSelectionFlags(pushCmd)
	pushCmd.Flags().SortFlags = false
	pushCmd.Flags().PrintDefaults()
}

func pushImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Pushing container image..")

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageNameFlagName, err)
	}

	if imageId == "" && imageName == "" {
		return errors.New("no image id or image name provided")
	}

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

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	if err := context.Providers().Image.Push(provider.ImagePushConfig{
		ImageId:    imageId,
		ImageName:  imageName,
		Nodes:      nodeSelector,
		ShowOutput: showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

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

	if imageId == "" && imageName == "" {
		return "", nil, errors.New("no image id or image name provided")
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Push-Image.ps1"))

	if imageId != "" {
		params = append(params, " -Id "+imageId)
	}
	if imageName != "" {
		params = append(params, " -ImageName "+imageName)
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return "", nil, err
	}
	params = appendNodesParam(params, nodeSelector)

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
