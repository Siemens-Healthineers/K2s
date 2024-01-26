// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	"k2s/setupinfo"
	"k2s/utils"
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Remove container images from all nodes",
	RunE:  cleanImages,
}

func cleanImages(cmd *cobra.Command, args []string) error {
	cleanImagesCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\CleanImages.ps1")

	// by default enable show logs
	cleanImagesCommand += " -ShowLogs"

	klog.V(3).Infof("Clean images command: %s", cleanImagesCommand)
	duration, err := utils.ExecutePowershellScript(cleanImagesCommand)
	switch err {
	case nil:
		break
	case setupinfo.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	common.PrintCompletedMessage(duration, "Clean")

	return nil
}
