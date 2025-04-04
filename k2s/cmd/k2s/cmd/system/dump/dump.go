// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dump

import (
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
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
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	skipOpenDumpFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipOpenDumpFlagName).Value.String())
	if err != nil {
		return err
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	dumpStatusCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "dump", "dump.ps1"))

	if skipOpenDumpFlag {
		dumpStatusCommand += " -OpenDumpFolder `$false"
	}

	if outputFlag {
		dumpStatusCommand += " -ShowLogs"
	}

	slog.Debug("PS command created", "command", dumpStatusCommand)

	err = powershell.ExecutePs(dumpStatusCommand, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
