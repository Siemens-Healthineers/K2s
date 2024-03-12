// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package uninstall

import (
	"errors"
	"log/slog"
	"strconv"

	"base/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
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
	Uninstallk8sCmd.Flags().String(p.AdditionalHooksDirFlagName, "", p.AdditionalHooksDirFlagUsage)
	Uninstallk8sCmd.Flags().BoolP(p.DeleteFilesFlagName, p.DeleteFilesFlagShorthand, false, p.DeleteFilesFlagUsage)
	Uninstallk8sCmd.Flags().SortFlags = false
	Uninstallk8sCmd.Flags().PrintDefaults()
}

func uninstallk8s(ccmd *cobra.Command, args []string) error {
	version := version.GetVersion()

	pterm.Printfln("🤖 Uninstalling K2s %s", version)

	uninstallCmd, err := buildUninstallCmd(ccmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", uninstallCmd)

	duration, err := psexecutor.ExecutePowershellScript(uninstallCmd)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Uninstallation")

	return nil
}

func buildUninstallCmd(ccmd *cobra.Command) (string, error) {
	skipPurgeFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(skipPurge).Value.String())
	if err != nil {
		return "", err
	}

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	additionalHooksDir := ccmd.Flags().Lookup(p.AdditionalHooksDirFlagName).Value.String()

	config := c.NewAccess()

	setupName, err := config.GetSetupName()
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return "", common.CreateSystemNotInstalledCmdFailure()
		}
		return "", err
	}

	deleteFilesForOfflineInstallation, err := strconv.ParseBool(ccmd.Flags().Lookup(p.DeleteFilesFlagName).Value.String())
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
		return "", errors.New("could not determine the setup type, aborting. If you are sure you have a K2s setup installed, call the correct uninstall script directly")
	}

	return cmd, nil
}

func buildk2sUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(c.SmallSetupDir() + "\\" + "UninstallK8s.ps1")

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
	cmd := utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\common\\" + "UninstallBuildOnlySetup.ps1")

	if showLogs {
		cmd += " -ShowLogs"
	}

	if deleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}

	return cmd
}

func buildMultiVMUninstallCmd(skipPurge bool, showLogs bool, additionalHooksDir string, deleteFilesForOfflineInstallation bool) string {
	cmd := utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\multivm\\" + "Uninstall_MultiVMK8sSetup.ps1")

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
