// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	"k2s/setupinfo"
	"k2s/utils"
)

const (
	defaultImageId   = ""
	defaultImageName = ""
)

var (
	imageIdLabel      = "id"
	imageNameLabel    = "name"
	fromRegistryLabel = "from-registry"
)

type removeOptions struct {
	ImageId      string
	ImageName    string
	FromRegistry bool
}

var removeExample = `
  # Delete image by id
  k2s image rm --id 042a816809aa

  # Delete pushed image from registry
  k2s image rm --name k2s-registry.local/alpine:v1 --from-registry
`

var removeCmd = &cobra.Command{
	Use:     "rm",
	Short:   "Remove container image using image id or image name",
	Example: removeExample,
	RunE:    removeImage,
}

func init() {
	addInitFlagsForRemoveCommand(removeCmd)
}

func addInitFlagsForRemoveCommand(cmd *cobra.Command) {
	cmd.Flags().String(imageIdLabel, defaultImageId, "Image ID of the container image")
	cmd.Flags().String(imageNameLabel, defaultImageName, "Name of the container image")
	cmd.Flags().Bool(fromRegistryLabel, false, "Remove image from registry")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func extractRemoveOptions(cmd *cobra.Command) (*removeOptions, error) {
	imageId, err := cmd.Flags().GetString(imageIdLabel)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag: %s", imageIdLabel)
	}
	imageName, err := cmd.Flags().GetString(imageNameLabel)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag: %s", imageNameLabel)
	}
	fromRegistry, err := strconv.ParseBool(cmd.Flags().Lookup(fromRegistryLabel).Value.String())
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag: %s", fromRegistryLabel)
	}
	removeOptions := &removeOptions{
		ImageId:      imageId,
		ImageName:    imageName,
		FromRegistry: fromRegistry,
	}
	return removeOptions, nil
}

func buildRemoveCommand(removeOptions *removeOptions) string {
	cmd := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\RemoveImage.ps1")
	if removeOptions.ImageId != "" {
		cmd += " -ImageId " + removeOptions.ImageId
	}
	if removeOptions.ImageName != "" {
		cmd += " -ImageName " + removeOptions.ImageName
	}
	if removeOptions.FromRegistry {
		cmd += " -FromRegistry"
	}

	cmd += " -ShowLogs"

	return cmd
}

func removeImage(cmd *cobra.Command, args []string) error {
	removeOptions, err := extractRemoveOptions(cmd)
	if err != nil {
		return err
	}
	removeCommand := buildRemoveCommand(removeOptions)
	klog.V(3).Infof("Remove Image command: %s", removeCommand)

	duration, err := utils.ExecutePowershellScript(removeCommand)
	switch err {
	case nil:
		break
	case setupinfo.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	common.PrintCompletedMessage(duration, "Remove")

	return nil
}
