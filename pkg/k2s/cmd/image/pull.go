// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	"k2s/utils"
	"strconv"

	"github.com/spf13/cobra"
)

const (
	pullForWindowsFlag          = "windows"
	pullForWindowsFlagShorthand = "w"
	pullForWindowsDefault       = false
	pullForWindowsFlagDesc      = "Pull image on windows node"
)

var pullCommandExample = `
  # Pull a linux image onto the linux node
  k2s image pull nginx:latest

  # Pull a windows image onto a windows 10 node
  k2s image pull mcr.microsoft.com/windows:20H2 --windows 
  OR
  k2s image pull mcr.microsoft.com/windows:20H2 -w
`

var pullCmd = &cobra.Command{
	Use:     "pull",
	Short:   "Pull an image onto a kubernetes node",
	Example: pullCommandExample,
	RunE:    pullImages,
}

func init() {
	pullCmd.Flags().BoolP(pullForWindowsFlag, pullForWindowsFlagShorthand, pullForWindowsDefault, pullForWindowsFlagDesc)
	pullCmd.Flags().SortFlags = false
	pullCmd.Flags().PrintDefaults()
}

func pullImages(cmd *cobra.Command, args []string) error {
	err := validateArgs(args)
	if err != nil {
		return fmt.Errorf("Invalid arguments provided. Error : %s", err)
	}

	imageToPull := getImageToPull(args)
	pullForWindows, _ := strconv.ParseBool(cmd.Flags().Lookup(pullForWindowsFlag).Value.String())

	pullImagePowershellCommand := createPowershellCommandToPullImage(imageToPull, pullForWindows)

	duration, err := utils.ExecutePowershellScript(pullImagePowershellCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Pull")

	return nil
}

func validateArgs(args []string) error {
	if len(args) == 0 {
		return errors.New("no image to pull")
	}

	if len(args) > 1 {
		return errors.New("more than 1 image to pull. Can only pull 1 image at a time")
	}

	return nil
}

func getImageToPull(args []string) string {
	return args[0]
}

func createPowershellCommandToPullImage(imageToPull string, pullForWindows bool) string {
	pullImagePowershellCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\PullImage.ps1")

	pullImagePowershellCommand += fmt.Sprintf(" -ImageName %s", imageToPull)

	if pullForWindows {
		pullImagePowershellCommand += " -Windows"
	}

	// for pulling images set show logs to true by default
	pullImagePowershellCommand += " -ShowLogs"

	return pullImagePowershellCommand
}
