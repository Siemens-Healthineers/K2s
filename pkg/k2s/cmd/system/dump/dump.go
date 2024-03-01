// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package dump

import (
	"errors"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
)

var (
	skipOpenDumpFlagName = "skip-open"
)

var DumpCmd = &cobra.Command{
	Use:   "dump",
	Short: "Dump system status",
	Long:  "Dump system status to target folder",
	RunE:  dumpSystemStatus,
}

func init() {
	DumpCmd.Flags().BoolP(skipOpenDumpFlagName, "S", false, "If set to true, opening the dump target folder will be skipped")
	DumpCmd.Flags().SortFlags = false
	DumpCmd.Flags().PrintDefaults()
}

func dumpSystemStatus(cmd *cobra.Command, args []string) error {
	skipOpenDumpFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipOpenDumpFlagName).Value.String())
	if err != nil {
		return err
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	dumpStatusCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\debug\\DumpSystemStatus.ps1")

	if skipOpenDumpFlag {
		dumpStatusCommand += " -OpenDumpFolder `$false"
	}

	if outputFlag {
		dumpStatusCommand += " -ShowLogs `$true"
	}

	klog.V(3).Infof("Dump system status command: %s", dumpStatusCommand)

	duration, err := psexecutor.ExecutePowershellScript(dumpStatusCommand)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	common.PrintCompletedMessage(duration, "system dump")

	return nil
}
