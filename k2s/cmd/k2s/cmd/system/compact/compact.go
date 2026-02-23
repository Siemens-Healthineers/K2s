// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package compact

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
)

var (
	noRestartFlag  bool
	skipFstrimFlag bool
	yesFlag        bool
)

var CompactCmd = &cobra.Command{
	Use:   "compact",
	Short: "Compact VHDX disk to reclaim unused space",
	Long: `Compacts the Kubemaster VHDX file to reclaim disk space freed by deleted images and files.

This command performs the following steps:
1. Runs fstrim inside the VM to notify Hyper-V of freed blocks (if cluster is running)
2. Stops the cluster
3. Optimizes the VHDX file to reclaim space
4. Restarts the cluster (unless --no-restart is specified)

Note: This operation may take several minutes depending on the VHDX size.`,
	Example: `  # Compact VHDX with automatic cluster restart
  k2s system compact

  # Compact without restarting cluster
  k2s system compact --no-restart

  # Skip confirmation prompts
  k2s system compact --yes`,
	RunE: compactVhdx,
}

func init() {
	CompactCmd.Flags().BoolVar(&noRestartFlag, "no-restart", false, "Do not restart cluster after compaction")
	CompactCmd.Flags().BoolVar(&skipFstrimFlag, "skip-fstrim", false, "Skip running fstrim inside VM (advanced use only)")
	CompactCmd.Flags().BoolVarP(&yesFlag, "yes", "y", false, "Skip confirmation prompts")
	CompactCmd.Flags().SortFlags = false
	CompactCmd.Flags().PrintDefaults()
}

func compactVhdx(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	compactCommand, err := buildCompactCmd(outputFlag)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", compactCommand)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if !errors.Is(err, cconfig.ErrSystemInCorruptedState) && !errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return err
		}
	}

	if runtimeConfig != nil && runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	err = powershell.ExecutePs(compactCommand, common.NewPtermWriter())
	if err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildCompactCmd(outputFlag bool) (string, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "compact", "Invoke-VhdxCompaction.ps1"))

	params := ""
	if noRestartFlag {
		params += " -NoRestart"
	}
	if skipFstrimFlag {
		params += " -SkipFstrim"
	}
	if yesFlag {
		params += " -Yes"
	}
	if outputFlag {
		params += " -ShowLogs"
	}

	return scriptPath + params, nil
}

