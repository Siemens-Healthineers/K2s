// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package restore

import (
	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/provider"
)

const (
	restoreFileFlag    = "file"
	errorOnFailureFlag = "error-on-failure"
)

var SystemRestoreCmd = &cobra.Command{
	Use:   "restore",
	Short: "Restores K2s cluster resources from a backup",
	RunE:  runSystemRestore,
}

func init() {
	SystemRestoreCmd.Flags().SortFlags = false
	SystemRestoreCmd.Flags().StringP(restoreFileFlag, "f", "", "Backup file to restore from (zip)")
	_ = SystemRestoreCmd.MarkFlagRequired(restoreFileFlag)
	SystemRestoreCmd.Flags().BoolP(errorOnFailureFlag, "e", false, "Fail if errors occur while restoring resources")
	SystemRestoreCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
}

func runSystemRestore(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	defer cmdSession.Finish()

	pterm.Println("📦 Restoring K2s system backup ...")

	out, err := cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}

	backupFile, err := cmd.Flags().GetString(restoreFileFlag)
	if err != nil {
		return err
	}

	errorOnFailure, err := cmd.Flags().GetBool(errorOnFailureFlag)
	if err != nil {
		return err
	}

	additionalHooksDir, err := cmd.Flags().GetString(common.AdditionalHooksDirFlagName)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	return context.Providers().System.Restore(provider.SystemRestoreConfig{
		BackupFile:         backupFile,
		AdditionalHooksDir: additionalHooksDir,
		ErrorOnFailure:     errorOnFailure,
		ShowOutput:         out,
	})
}
