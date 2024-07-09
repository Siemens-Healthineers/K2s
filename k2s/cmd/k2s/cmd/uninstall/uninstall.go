// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package uninstall

import (
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"
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
	version := version.GetVersion()

	pterm.Printfln("🤖 Uninstalling K2s %s", version)

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

	uninstallCmd, err := buildUninstallCmd(cmd.Flags(), config.SetupName)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", uninstallCmd)

	start := time.Now()

	err = powershell.ExecutePs(uninstallCmd, common.DeterminePsVersion(config), common.NewOutputWriter())
	if err != nil {
		return err
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "Uninstallation")

	return nil
}

func buildUninstallCmd(flags *pflag.FlagSet, setupName setupinfo.SetupName) (string, error) {
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

	switch setupName {
	case setupinfo.SetupNamek2s:
		cmd = buildk2sUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
	case setupinfo.SetupNameBuildOnlyEnv:
		cmd = buildBuildOnlyUninstallCmd(outputFlag, deleteFilesForOfflineInstallation)
	case setupinfo.SetupNameMultiVMK8s:
		cmd = buildMultiVMUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
	default:
		slog.Warn("Uninstall", "Found invalid setup type", string(setupName))
		pterm.Warning.Printfln("could not determine the setup type, proceeding uninstall with default variant 'k2s'")
		cmd = buildk2sUninstallCmd(skipPurgeFlag, outputFlag, additionalHooksDir, deleteFilesForOfflineInstallation)
	}

	return cmd, nil
}

func buildk2sUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\UninstallK8s.ps1")

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
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\common\\UninstallBuildOnlySetup.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if deleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return cmd
}

func buildMultiVMUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(utils.InstallDir() + "\\smallsetup\\multivm\\Uninstall_MultiVMK8sSetup.ps1")

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
