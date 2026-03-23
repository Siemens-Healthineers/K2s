// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package uninstall

import (
	"errors"
	"strconv"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/provider"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
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
	ver := version.GetVersion()

	pterm.Printfln("🤖 Uninstalling K2s %s", ver)

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

	// Read flags
	skipPurgeFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipPurge).Value.String())
	if err != nil {
		return err
	}
	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	deleteFiles, err := strconv.ParseBool(cmd.Flags().Lookup(common.DeleteFilesFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	var setupName string
	var linuxOnly bool
	if runtimeConfig != nil {
		setupName = runtimeConfig.InstallConfig().SetupName()
		linuxOnly = runtimeConfig.InstallConfig().LinuxOnly()
	}

	// Uninstall via provider (handles platform dispatch)
	err = context.Providers().Cluster.Uninstall(provider.ClusterUninstallConfig{
		ShowLogs:                          outputFlag,
		SkipPurge:                         skipPurgeFlag,
		DeleteFilesForOfflineInstallation: deleteFiles,
		AdditionalHooksDir:                additionalHooksDir,
		ConfigDir:                         context.Config().Host().K2sSetupConfigDir(),
		SetupName:                         setupName,
		LinuxOnly:                         linuxOnly,
	})
	if err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}
