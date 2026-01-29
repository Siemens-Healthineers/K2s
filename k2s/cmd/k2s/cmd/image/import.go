// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/spf13/cobra"
)

const (
	windowsFlag       = "windows"
	dockerArchiveFlag = "docker-archive"
	tarFlag           = "tar"
	dirFlag           = "dir"
)

var (
	importCmd = &cobra.Command{
		Use:     "import",
		Short:   "Import an image from a tar archive",
		Example: importCommandExample,
		RunE:    importImage,
	}

	importCommandExample = `
  # Import an linux image from an oci tar archive
  k2s image import -t C:\tmp\image.tar

  # Import an linux image from an docker tar archive
  k2s image import -t C:\tmp\dockerimage.tar --docker-archive

  # Import linux images from a directory
  k2s image import -d C:\tmp\images 

  # Import an windows image from a tar archive
  k2s image import -t C:\tmp\image.tar -w
`
)

func init() {
	importCmd.Flags().StringP(tarFlag, "t", "", "oci archive (tar)")
	importCmd.Flags().StringP(dirFlag, "d", "", "Path to directory with oci archives (tar) to import")
	importCmd.Flags().BoolP(windowsFlag, "w", false, "Windows image")
	importCmd.Flags().Bool(dockerArchiveFlag, false, "Import Linux image from docker-archive tar (default: oci-archive)")
	importCmd.Flags().SortFlags = false
	importCmd.Flags().PrintDefaults()
}

func importImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	isWindowsImage, err := strconv.ParseBool(cmd.Flags().Lookup(windowsFlag).Value.String())
	if err != nil {
		return err
	}

	psCmd, params, err := buildImportPsCmd(cmd, isWindowsImage)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

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

	if runtimeConfig.InstallConfig().LinuxOnly() && isWindowsImage {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

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

func buildImportPsCmd(cmd *cobra.Command, isWindowsImage bool) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Import-Image.ps1"))

	imagePath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	dir, err := cmd.Flags().GetString(dirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", dirFlag, err)
	}

	if imagePath != "" && dir != "" {
		params = append(params, " -ImagePath '"+imagePath+"'")
	} else if imagePath != "" {
		params = append(params, " -ImagePath '"+imagePath+"'")
	} else if dir != "" {
		params = append(params, " -ImageDir '"+dir+"'")
	} else {
		return "", nil, errors.New("no path to oci archive provided")
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if isWindowsImage {
		params = append(params, " -Windows")
	}

	if isDockerArchive {
		params = append(params, " -DockerArchive")
	}

	return
}
