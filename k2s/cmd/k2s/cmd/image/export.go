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

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/spf13/cobra"
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

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
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

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), common.NewOutputWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
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

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Export-Image.ps1"))

	params = append(params, " -Id '"+imageId+"'", " -Name '"+imageName+"'", " -ExportPath '"+exportPath+"'")

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if isDockerArchive {
		params = append(params, " -DockerArchive")
	}

	return
}
