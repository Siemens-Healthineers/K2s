// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package scp

import (
	"errors"
	"k2s/cmd/common"
	"k2s/setupinfo"
	"k2s/utils"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var buildCommandExampleForWorker = `
  # Copy a yaml manifest from local machine to WinNode VM in multi-vm setup
  k2s system scp w C:\tmp\manifest.yaml C:\tmp\worker\manifest.yaml

  # Copy a yaml manifest from WinNode VM to local machine in multi-vm setup
  k2s system scp w C:\tmp\worker\manifest.yaml C:\tmp\manifest.yaml -r
`

var scpWorkerCmd = &cobra.Command{
	Use:     "w SOURCE TARGET",
	Short:   "Copy from local machine to WinNode VM in multi-vm setup",
	Example: buildCommandExampleForWorker,
	RunE:    scpWorker,
}

func init() {
	scpWorkerCmd.Flags().BoolP(reverseFlag, "r", false, "Reverse direction: Copy from WinNode VM to local machine")
	scpWorkerCmd.Flags().SortFlags = false
	scpWorkerCmd.Flags().PrintDefaults()
}

func scpWorker(ccmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no source path specified")
	}

	if args[1] == "" {
		return errors.New("no target path specified")
	}

	scpCmd, err := buildScpCmdForMultiVM(ccmd, args)
	if err != nil {
		return err
	}

	klog.V(3).Infof("scp command : %s", scpCmd)

	_, err = utils.ExecutePowershellScript(scpCmd)

	if err == setupinfo.ErrNotInstalled {
		common.PrintNotInstalledMessage()
		return nil
	}

	return err
}

func buildScpCmdForMultiVM(ccmd *cobra.Command, args []string) (string, error) {
	source := args[0]
	target := args[1]

	scpCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory()+"\\smallsetup\\helpers\\scpw.ps1") + " -Source '" + source + "' -Target '" + target + "'"

	reverse, err := strconv.ParseBool(ccmd.Flags().Lookup(reverseFlag).Value.String())
	if err != nil {
		return "", err
	}

	if reverse {
		scpCommand += " -Reverse"
	}

	return scpCommand, nil
}
