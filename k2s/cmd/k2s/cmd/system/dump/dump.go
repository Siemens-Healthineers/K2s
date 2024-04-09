// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package dump

import (
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
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
	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	skipOpenDumpFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipOpenDumpFlagName).Value.String())
	if err != nil {
		return err
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	dumpStatusCommand := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\debug\\DumpSystemStatus.ps1")

	if skipOpenDumpFlag {
		dumpStatusCommand += " -OpenDumpFolder `$false"
	}

	if outputFlag {
		dumpStatusCommand += " -ShowLogs `$true"
	}

	slog.Debug("PS command created", "command", dumpStatusCommand)

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	start := time.Now()

	err = powershell.ExecutePs(dumpStatusCommand, common.DeterminePsVersion(config), outputWriter)
	if err != nil {
		return err
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "system dump")

	return nil
}
