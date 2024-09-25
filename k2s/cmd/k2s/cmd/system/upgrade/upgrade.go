// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	bl "github.com/siemens-healthineers/k2s/internal/logging"
	"github.com/siemens-healthineers/k2s/internal/os"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

var upgradeCommandShortDescription = "Upgrades the installed K2s cluster to this version"

var upgradeCommandLongDescription = `
Upgrades the installed K2s cluster to this version.

⚠  This command must be called within the folder containing the new K2s version, e.g. '<new-version-dir>\k2s.exe system upgrade'

The following tasks will be executed:
1. Export of current workloads (global resources and all namespaced resources)
2. Keeping addons and their persistency to be re-enabled after cluster upgrade
3. Uninstall existing cluster
4. Install a new cluster based on this version
5. Import previously exported workloads
6. Enable addons and restore persistency
7. Check if all workloads are running
8. Finally check K2s cluster availability
`

var upgradeCommandExample = `
  # Upgrades the cluster to this version
  k2s system upgrade

  # Upgrades the cluster to this version, skips takeover of existing cluster resources
  k2s system upgrade -s

  # Upgrades the cluster to this version, deleting downloaded files after upgrade
  k2s system upgrade -d
`

const (
	configFileFlagName = "config"
	skipK8sResources   = "skip-resources"
	deleteFiles        = "delete-files"
	proxy              = "proxy"
	defaultProxy       = ""
	skipImages         = "skip-images"
	backupDir          = "backup-dir"
	defaultBackupDir   = ""
)

var UpgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   upgradeCommandShortDescription,
	Long:    upgradeCommandLongDescription,
	RunE:    upgradeCluster,
	Example: upgradeCommandExample,
}

func init() {
	AddInitFlags(UpgradeCmd)
}

func AddInitFlags(cmd *cobra.Command) {
	cmd.Flags().BoolP(skipK8sResources, "s", false, "Skip takeover of K8s resources from old cluster to new cluster")
	cmd.Flags().BoolP(deleteFiles, "d", false, "Delete downloaded files")
	cmd.Flags().StringP(configFileFlagName, "c", "", "Path to config file to load. This configuration overwrites other CLI parameters")
	cmd.Flags().StringP(proxy, "p", defaultProxy, "HTTP Proxy")
	cmd.Flags().StringP(backupDir, "b", defaultBackupDir, "Backup directory")
	cmd.Flags().BoolP(skipImages, "i", false, "Skip takeover of container images from old cluster to new cluster")
	cmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func upgradeCluster(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Analyze current cluster and check prerequisites ...")

	showLog, err := cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	config, err := readConfigLegacyAware(context.Config())
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
	}

	psCmd := createUpgradeCommand(cmd)

	slog.Debug("PS command created", "command", psCmd)

	outputWriter := common.NewPtermWriter()

	start := time.Now()

	switchToUpgradeLogFile(showLog, context.Logger())

	psErr := powershell.ExecutePs(psCmd, common.DeterminePsVersion(config), outputWriter)

	switchToDefaultLogFile(showLog, context.Logger())

	if psErr != nil {
		return psErr
	}

	if outputWriter.ErrorOccurred {
		return common.CreateSystemUnableToUpgradeCmdFailure()
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, "Upgrade")

	return nil
}

func readConfigLegacyAware(cfg *config.Config) (*setupinfo.Config, error) {
	slog.Info("Trying to read the config file", "config-dir", cfg.Host.K2sConfigDir)

	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return nil, err
		}

		slog.Info("Config file not found, trying to read the config file from legacy dir", "legacy-dir", cfg.Host.KubeConfigDir)

		config, err = setupinfo.ReadConfig(cfg.Host.KubeConfigDir)
		if err != nil {
			return nil, err
		}

		if err := copyLegacyConfigFile(cfg.Host.KubeConfigDir, cfg.Host.K2sConfigDir); err != nil {
			return nil, err
		}
	}

	slog.Info("Config file read")

	return config, nil
}

func copyLegacyConfigFile(legacyDir string, targetDir string) error {
	slog.Info("Copying config file from legacy dir to target dir", "legacy-dir", legacyDir, "target-dir", targetDir)

	if err := os.CreateDirIfNotExisting(targetDir); err != nil {
		return err
	}
	if err := os.CopyFile(setupinfo.ConfigPath(legacyDir), setupinfo.ConfigPath(targetDir)); err != nil {
		return err
	}
	return nil
}

func createUpgradeCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "upgrade", "Start-ClusterUpgrade.ps1"))
	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		slog.Debug("Param", "name", f.Name, "value", f.Value)
	})
	out, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if out {
		psCmd += " -ShowLogs"
	}
	skip, _ := strconv.ParseBool(cmd.Flags().Lookup(skipK8sResources).Value.String())
	if skip {
		psCmd += " -SkipResources "
	}
	delete, _ := strconv.ParseBool(cmd.Flags().Lookup(deleteFiles).Value.String())
	if delete {
		psCmd += " -DeleteFiles "
	}
	config := cmd.Flags().Lookup(configFileFlagName).Value.String()
	if len(config) > 0 {
		psCmd += " -Config " + config
	}
	proxy := cmd.Flags().Lookup(proxy).Value.String()
	if len(proxy) > 0 {
		psCmd += " -Proxy " + proxy
	}
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImages).Value.String())
	if skipImages {
		psCmd += " -SkipImages"
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	if additionalHooksDir != "" {
		psCmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}
	backupDir := cmd.Flags().Lookup(backupDir).Value.String()
	if backupDir != "" {
		psCmd += " -BackupDir " + utils.EscapeWithSingleQuotes(backupDir)
	}
	return psCmd
}

func switchToUpgradeLogFile(showLog bool, logger *logging.Slogger) {
	upgradeLogFilePath := bl.GlobalLogFilePath() + "_cli_upgrade_" + time.Now().Format("2006-01-02_15-04-05")

	slog.Debug("Switching temporary to CLI upgrade log file", "path", upgradeLogFilePath)

	setLogger(showLog, logger, upgradeLogFilePath)
}

func switchToDefaultLogFile(showLog bool, logger *logging.Slogger) {
	globalLogFilePath := bl.GlobalLogFilePath()

	slog.Debug("Switching back to default log file", "path", globalLogFilePath)

	setLogger(showLog, logger, globalLogFilePath)
}

func setLogger(showLog bool, logger *logging.Slogger, path string) {
	logHandlers := []logging.HandlerBuilder{logging.NewFileHandler(path)}
	if showLog {
		logHandlers = append(logHandlers, logging.NewCliHandler())
	}
	logger.SetHandlers(logHandlers...).SetGlobally()
}
