// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package compact

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/tz"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
)

var (
	noRestartFlag bool
	yesFlag       bool
)

var CompactCmd = &cobra.Command{
	Use:   "compact",
	Short: "Compact VHDX disk to reclaim unused space",
	Long: `Compacts the Kubemaster VHDX file to reclaim disk space freed by deleted images and files.

This command performs the following steps:
1. Runs fstrim inside the VM to notify Hyper-V of freed blocks (if cluster is running)
2. Stops the cluster (always required for VHDX optimization)
3. Optimizes the VHDX file to reclaim space
4. Restarts the cluster (unless --no-restart is specified)

Note: This operation may take several minutes depending on the VHDX size.`,
	Example: `  # Compact VHDX with automatic cluster restart
  k2s system compact

  # Compact and keep cluster stopped afterwards (stop still happens)
  k2s system compact --no-restart

  # Skip confirmation prompts
  k2s system compact --yes`,
	RunE: compactVhdx,
}

func init() {
	CompactCmd.Flags().BoolVar(&noRestartFlag, "no-restart", false, "Keep cluster stopped after compaction (cluster is always stopped during compaction)")
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
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	tzConfigHandle, err := tz.NewTimezoneConfigWorkspace(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	handle, err := tzConfigHandle.CreateHandle()
	if err != nil {
		return err
	}
	defer handle.Release()

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
	if yesFlag {
		params += " -Yes"
	}
	if outputFlag {
		params += " -ShowLogs"
	}

	return scriptPath + params, nil
}

