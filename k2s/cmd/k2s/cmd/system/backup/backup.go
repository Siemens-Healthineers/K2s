package backup

import (
	"strconv"
	"fmt"
	"time"
	"path/filepath"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

const (
	backupFileFlag = "file"
	defaultBackupDir = "C:\\temp"
)

var SystemBackupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Creates a backup of the K2s cluster resources",
	RunE:  runSystemBackup,
}

func init() {
	SystemBackupCmd.Flags().SortFlags = false // keep as-is

	SystemBackupCmd.Flags().StringP(
		backupFileFlag,
		"f",
		"",
		"Backup file to create (zip). If omitted, a default file in C:\\temp is generated",
	)

	SystemBackupCmd.Flags().String(
		common.AdditionalHooksDirFlagName,
		"",
		common.AdditionalHooksDirFlagUsage,
	)
}

func runSystemBackup(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("📦 Creating K2s system backup ...")

	psCmd := createSystemBackupPsCommand(cmd)

	outputWriter := common.NewPtermWriter()
	if err := powershell.ExecutePs(psCmd, outputWriter); err != nil {
		return err
	}

	if outputWriter.ErrorOccurred {
		return fmt.Errorf("system backup failed: PowerShell script encountered errors")
	}

	cmdSession.Finish()
	return nil
}

func createSystemBackupPsCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(
		utils.InstallDir() +
			"\\lib\\scripts\\k2s\\system\\backup\\Start-SystemBackup.ps1",
	)

	out, _ := strconv.ParseBool(
		cmd.Flags().Lookup(common.OutputFlagName).Value.String(),
	)
	if out {
		psCmd += " -ShowLogs"
	}

	backupFile := resolveBackupFileName(cmd)
	psCmd += " -BackupFile " + utils.EscapeWithSingleQuotes(backupFile)

	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	if additionalHooksDir != "" {
		psCmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	return psCmd
}

func resolveBackupFileName(cmd *cobra.Command) string {
	file := cmd.Flags().Lookup(backupFileFlag).Value.String()
	if file != "" {
		return file
	}

	timestamp := time.Now().Format("2006-01-02_15-04-05")
	filename := fmt.Sprintf("k2s-backup-file-%s.zip", timestamp)
	return filepath.Join(defaultBackupDir, filename)
}
