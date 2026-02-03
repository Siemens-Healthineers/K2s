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
	skipImagesFlag = "skip-images"
	skipPVsFlag    = "skip-pvs"
	defaultBackupDir = "C:\\Temp\\k2s\\backups"
)


var SystemBackupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Backs up cluster resources, persistent volumes, and user application images",
	RunE:  runSystemBackup,
}

func init() {
	SystemBackupCmd.Flags().SortFlags = false

	SystemBackupCmd.Flags().StringP(
		backupFileFlag,
		"f",
		"",
		"Backup file to create (zip). If omitted, a default file in C://Temp/k2s/backups is generated",
	)

	SystemBackupCmd.Flags().String(
		common.AdditionalHooksDirFlagName,
		"",
		common.AdditionalHooksDirFlagUsage,
	)

	SystemBackupCmd.Flags().Bool(
		skipImagesFlag,
		false,
		"Skip backing up container images",
	)

	SystemBackupCmd.Flags().Bool(
		skipPVsFlag,
		false,
		"Skip backing up persistent volumes",
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

	// Pass skip flags to PowerShell if set
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImagesFlag).Value.String())
	if skipImages {
		psCmd += " -SkipImages"
	}

	skipPVs, _ := strconv.ParseBool(cmd.Flags().Lookup(skipPVsFlag).Value.String())
	if skipPVs {
		psCmd += " -SkipPVs"
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
