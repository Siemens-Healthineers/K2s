// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"k2s/setupinfo"
	"k2s/utils"
	"strconv"

	"k2s/cmd/common"
	p "k2s/cmd/params"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var exportCommandExample = `
  # Export an image as tar archive to filesystem
  k2s image export --id fcecffc7ad4a -t C:\tmp\exportedImage.tar
`

var exportCmd = &cobra.Command{
	Use:     "export",
	Short:   "Export an image to tar archive",
	Example: exportCommandExample,
	RunE:    exportImage,
}

const (
	defaultExportPath = ""
)

func init() {
	exportCmd.Flags().String(imageIdLabel, defaultImageId, "Image ID of the container image")
	exportCmd.Flags().StringP(imageNameLabel, "n", defaultImageName, "Name of the container image")
	exportCmd.Flags().StringP(tarLabel, "t", defaultExportPath, "Export tar file path")
	exportCmd.Flags().Bool(dockerArchiveFlag, false, "Export Linux image as docker-archive (default: oci-archive)")
	exportCmd.Flags().SortFlags = false
	exportCmd.Flags().PrintDefaults()
}

func exportImage(cmd *cobra.Command, args []string) error {
	exportCmd, err := buildExportCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("export command : %s", exportCmd)

	duration, err := utils.ExecutePowershellScript(exportCmd)
	switch err {
	case nil:
		break
	case setupinfo.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	common.PrintCompletedMessage(duration, "Export image")

	return nil
}

func buildExportCmd(ccmd *cobra.Command) (string, error) {
	imageId, err := ccmd.Flags().GetString(imageIdLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", imageIdLabel)
	}
	imageName, err := ccmd.Flags().GetString(imageNameLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", imageNameLabel)
	}
	if imageId == "" && imageName == "" {
		return "", errors.New("no image id or image name provided")
	}

	exportPath, err := ccmd.Flags().GetString(tarLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", tarLabel)
	}
	if exportPath == "" {
		return "", errors.New("no export path provided")
	}

	out, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	isDockerArchive, err := strconv.ParseBool(ccmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", err
	}

	exportCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory()+"\\smallsetup\\helpers\\ExportImage.ps1") + " -Id '" + imageId + "' -Name '" + imageName + "' -ExportPath '" + exportPath + "'"

	if out {
		exportCommand += " -ShowLogs"
	}

	if isDockerArchive {
		exportCommand += " -DockerArchive"
	}

	return exportCommand, nil
}
