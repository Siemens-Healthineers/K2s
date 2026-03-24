// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dump

import (
	"strconv"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/provider"
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

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	if err := context.Providers().System.Dump(provider.SystemDumpConfig{
		SkipOpenDump: skipOpenDumpFlag,
		ShowOutput:   outputFlag,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
