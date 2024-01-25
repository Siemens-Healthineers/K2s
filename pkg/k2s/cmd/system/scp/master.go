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

var buildCommandExampleForMaster = `
  # Copy a yaml manifest from local machine to KubeMaster
  k2s system scp m C:\tmp\manifest.yaml /tmp

  # Copy a yaml manifest from KubeMaster to local machine
  k2s system scp m /tmp C:\tmp\manifest.yaml -r
`

const (
	sourceFlag  = "source"
	targetFlag  = "target"
	reverseFlag = "reverse"
)

var scpMasterCmd = &cobra.Command{
	Use:     "m SOURCE TARGET",
	Short:   "Copy from local machine to KubeMaster",
	Example: buildCommandExampleForMaster,
	RunE:    scpMaster,
}

func init() {
	scpMasterCmd.Flags().BoolP(reverseFlag, "r", false, "Reverse direction: Copy from KubeMaster to local machine")
	scpMasterCmd.Flags().SortFlags = false
	scpMasterCmd.Flags().PrintDefaults()
}

func scpMaster(ccmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no source path specified")
	}

	if args[1] == "" {
		return errors.New("no target path specified")
	}

	scpCmd, err := buildScpCmd(ccmd, args)
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

func buildScpCmd(ccmd *cobra.Command, args []string) (string, error) {
	source := args[0]
	target := args[1]

	scpCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory()+"\\smallsetup\\helpers\\scpm.ps1") + " -Source '" + source + "' -Target '" + target + "'"

	reverse, err := strconv.ParseBool(ccmd.Flags().Lookup(reverseFlag).Value.String())
	if err != nil {
		return "", err
	}

	if reverse {
		scpCommand += " -Reverse"
	}

	return scpCommand, nil
}
