// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"
	"time"

	"k2s/cmd/common"
	p "k2s/cmd/params"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var (
	exportCommandExample = `
  # Export an image as tar archive to filesystem
  k2s image export --id fcecffc7ad4a -t C:\tmp\exportedImage.tar
`

	exportCmd = &cobra.Command{
		Use:     "export",
		Short:   "Export an image to tar archive",
		Example: exportCommandExample,
		RunE:    exportImage,
	}
)

func init() {
	exportCmd.Flags().String(imageIdFlagName, "", "Image ID of the container image")
	exportCmd.Flags().StringP(removeImgNameFlagName, "n", "", "Name of the container image including tag")
	exportCmd.Flags().StringP(tarFlag, "t", "", "Export tar file path")
	exportCmd.Flags().Bool(dockerArchiveFlag, false, "Export Linux image as docker-archive (default: oci-archive)")
	exportCmd.Flags().SortFlags = false
	exportCmd.Flags().PrintDefaults()
}

func exportImage(cmd *cobra.Command, args []string) error {
	psCmd, params, err := buildExportPsCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image export")

	return nil
}

func buildExportPsCmd(cmd *cobra.Command) (psCmd string, params []string, err error) {
	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(removeImgNameFlagName)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", removeImgNameFlagName, err)
	}

	if imageId == "" && imageName == "" {
		return "", nil, errors.New("no image id or image name provided")
	}

	exportPath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	if exportPath == "" {
		return "", nil, errors.New("no export path provided")
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ExportImage.ps1")

	params = append(params, " -Id '"+imageId+"'", " -Name '"+imageName+"'", " -ExportPath '"+exportPath+"'")

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if isDockerArchive {
		params = append(params, " -DockerArchive")
	}

	return
}
