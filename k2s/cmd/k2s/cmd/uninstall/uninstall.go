// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package uninstall

import (
	"errors"
	"log/slog"
	"strconv"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

var (
	skipPurge       = "skip-purge"
	Uninstallk8sCmd = &cobra.Command{
		Use:   "uninstall",
		Short: "Uninstalls K2s cluster from the host machine",
		RunE:  uninstallk8s,
	}
)

func init() {
	Uninstallk8sCmd.Flags().Bool(skipPurge, false, "Skips purging all the files. This option is not set by default.")
	Uninstallk8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	Uninstallk8sCmd.Flags().BoolP(common.DeleteFilesFlagName, common.DeleteFilesFlagShorthand, false, common.DeleteFilesFlagUsage)
	Uninstallk8sCmd.Flags().SortFlags = false
	Uninstallk8sCmd.Flags().PrintDefaults()
}

func uninstallk8s(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	version := version.GetVersion()

	pterm.Printfln("🤖 Uninstalling K2s %s", version)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if !errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return err
		}
	}

	uninstallCmd, err := buildUninstallCmd(cmd.Flags(), runtimeConfig)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", uninstallCmd)

	err = powershell.ExecutePs(uninstallCmd, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildUninstallCmd(flags *pflag.FlagSet, config *cconfig.K2sRuntimeConfig) (string, error) {
	skipPurgeFlag, err := strconv.ParseBool(flags.Lookup(skipPurge).Value.String())
	if err != nil {
		return "", err
	}

	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	deleteFilesForOfflineInstallation, err := strconv.ParseBool(flags.Lookup(common.DeleteFilesFlagName).Value.String())
	if err != nil {
		return "", err
	}

	var cmd string

	switch config.InstallConfig().SetupName() {
	case definitions.SetupNameK2s:
		if config.InstallConfig().LinuxOnly() {
			cmd = buildLinuxOnlyUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
		} else {
			cmd = buildk2sUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
		}
	case definitions.SetupNameBuildOnlyEnv:
		cmd = buildBuildOnlyUninstallCmd(outputFlag, deleteFilesForOfflineInstallation)

	default:
		slog.Warn("Uninstall", "Found invalid setup type", config.InstallConfig().SetupName())
		pterm.Warning.Printfln("could not determine the setup type, proceeding uninstall with default variant 'k2s'")
		cmd = buildk2sUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
	}

	return cmd, nil
}

func buildk2sUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\k2s\\uninstall\\uninstall.ps1")

	if skipPurge {
		cmd += " -SkipPurge"
	}

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if deleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return cmd
}

func buildBuildOnlyUninstallCmd(showLogs bool, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\buildonly\\uninstall\\uninstall.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if deleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return cmd
}

func buildLinuxOnlyUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\lib\\scripts\\linuxonly\\uninstall\\uninstall.ps1")

	if skipPurge {
		cmd += " -SkipPurge"
	}

	if showLogs {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if deleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return cmd
}
