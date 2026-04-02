// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/provider"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/spf13/cobra"
)

var (
	exportCommandExample = `
  # Export image to tar archive; image is looked up on default nodes (Linux control-plane and local Windows host)
  k2s image export --id fcecffc7ad4a -t C:\tmp\exportedImage.tar

  # Export image that resides on a specific worker node
  k2s image export --node worker-1 --id fcecffc7ad4a -t C:\tmp\exportedImage.tar 

  # Export Linux image as docker-archive from a specific worker node
  k2s image export --node worker-1 --id fcecffc7ad4a -t C:\tmp\exportedImage.tar --docker-archive
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
	addNodeSelectionFlags(exportCmd)
	exportCmd.Flags().StringP(tarFlag, "t", "", "Export tar file path")
	exportCmd.Flags().Bool(dockerArchiveFlag, false, "Export Linux image as docker-archive (default: oci-archive)")
	exportCmd.Flags().SortFlags = false
	exportCmd.Flags().PrintDefaults()
}

func exportImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(removeImgNameFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", removeImgNameFlagName, err)
	}

	if imageId == "" && imageName == "" {
		return errors.New("no image id or image name provided")
	}

	exportPath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	if exportPath == "" {
		return errors.New("no export path provided")
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
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

	if err := context.Providers().Image.Export(provider.ImageExportConfig{
		ImageId:       imageId,
		ImageName:     imageName,
		Nodes:         nodeSelector,
		OutputPath:    exportPath,
		DockerArchive: isDockerArchive,
		ShowOutput:    showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

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

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return "", nil, err
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Export-Image.ps1"))

	params = append(params, " -Id '"+imageId+"'", " -Name '"+imageName+"'", " -ExportPath '"+exportPath+"'")
	params = appendNodesParam(params, nodeSelector)

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if isDockerArchive {
		params = append(params, " -DockerArchive")
	}

	return
}
