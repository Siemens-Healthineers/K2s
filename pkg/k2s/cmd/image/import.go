// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/setupinfo"
	"k2s/utils"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var importCommandExample = `
  # Import an linux image from an oci tar archive
  k2s image import -t C:\tmp\image.tar

  # Import an linux image from an docker tar archive
  k2s image import -t C:\tmp\dockerimage.tar --docker-archive

  # Import linux images from a directory
  k2s image import -d C:\tmp\images 

  # Import an windows image from a tar archive
  k2s image import -t C:\tmp\image.tar -w
`

const (
	windowsFlag       = "windows"
	dockerArchiveFlag = "docker-archive"
	tarLabel          = "tar"
	directoryLabel    = "dir"
	defaultTarBall    = ""
	defaultDir        = ""
)

var importCmd = &cobra.Command{
	Use:     "import",
	Short:   "Import an image from a tar archive",
	Example: importCommandExample,
	RunE:    importImage,
}

func init() {
	importCmd.Flags().StringP(tarLabel, "t", defaultTarBall, "oci archive (tar)")
	importCmd.Flags().StringP(directoryLabel, "d", defaultDir, "Path to directory with oci archives (tar) to import")
	importCmd.Flags().BoolP(windowsFlag, "w", false, "Windows image")
	importCmd.Flags().Bool(dockerArchiveFlag, false, "Import Linux image from docker-archive tar (default: oci-archive)")
	importCmd.Flags().SortFlags = false
	importCmd.Flags().PrintDefaults()
}

func importImage(cmd *cobra.Command, args []string) error {
	importCmd, err := buildImportCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("import command : %s", importCmd)

	duration, err := utils.ExecutePowershellScript(importCmd)
	switch err {
	case nil:
		break
	case setupinfo.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	common.PrintCompletedMessage(duration, "Import image")

	return nil
}

func buildImportCmd(ccmd *cobra.Command) (string, error) {
	importCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ImportImage.ps1")

	imagePath, err := ccmd.Flags().GetString(tarLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", tarLabel)
	}
	dir, err := ccmd.Flags().GetString(directoryLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", directoryLabel)
	}
	if imagePath != "" && dir != "" {
		importCommand += " -ImagePath '" + imagePath + "'"
	} else if imagePath != "" {
		importCommand += " -ImagePath '" + imagePath + "'"
	} else if dir != "" {
		importCommand += " -ImageDir '" + dir + "'"
	} else {
		return "", errors.New("no path to oci archive provided")
	}

	isWindowsImage, err := strconv.ParseBool(ccmd.Flags().Lookup(windowsFlag).Value.String())
	if err != nil {
		return "", err
	}

	out, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	isDockerArchive, err := strconv.ParseBool(ccmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", err
	}

	if out {
		importCommand += " -ShowLogs"
	}

	if isWindowsImage {
		importCommand += " -Windows"
	}

	if isDockerArchive {
		importCommand += " -DockerArchive"
	}

	return importCommand, nil
}
