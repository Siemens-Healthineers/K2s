// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package dump

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/config"
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
	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if !errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return err
		}
	}

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

	start := time.Now()

	err = powershell.ExecutePs(dumpStatusCommand, common.DeterminePsVersion(config), common.NewPsCommandOutputWriter())
	if err != nil {
		return err
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "system dump")

	return nil
}
