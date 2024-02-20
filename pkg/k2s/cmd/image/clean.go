// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/utils"
	"k2s/utils/psexecutor"
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Remove container images from all nodes",
	RunE:  cleanImages,
}

func cleanImages(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Cleaning container images..")

	psCmd := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\CleanImages.ps1")
	params := []string{}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
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

	common.PrintCompletedMessage(duration, "image clean")

	return nil
}
