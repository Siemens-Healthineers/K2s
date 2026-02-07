// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	bl "github.com/siemens-healthineers/k2s/internal/logging"
	kos "github.com/siemens-healthineers/k2s/internal/os"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

var upgradeCommandShortDescription = "Upgrades the installed K2s cluster to this version (full upgrade or in-place delta update)"

var upgradeCommandLongDescription = `
Upgrades the installed K2s cluster to this version.

⚠  This command automatically detects whether to perform:
   - FULL UPGRADE: if executed from a full K2s package directory (no delta-manifest.json)
   - DELTA UPDATE: if executed from an extracted delta package directory (delta-manifest.json present)

FULL UPGRADE:
  ⚠  Call this command within the folder containing the new K2s version, e.g. '<new-version-dir>\k2s.exe system upgrade'
  
  The following tasks will be executed:
  1. Export of current workloads (global resources and all namespaced resources)
  2. Uninstall existing cluster
  3. Install a new cluster based on this version
  4. Import previously exported workloads
  5. Re-enable previously enabled addons
  6. Check if all workloads are running
  7. Finally check K2s cluster availability

  ⚠  NOTE: Addon data/persistence is NOT automatically restored during upgrade.
     To backup and restore addon data, use the separate mechanisms:
     - k2s addons export / k2s addons import

DELTA UPDATE (EXPERIMENTAL):
  ⚠  Extract the delta package and call this command from within the extracted directory:
     1. Extract: Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
     2. Navigate: cd .\delta
     3. Update: .\k2s.exe system upgrade
  
  The following tasks will be executed:
  1. Detect delta package root (current directory with delta-manifest.json)
  2. Detect target installation folder (from setup.json)
  3. Update all Windows executables and scripts from delta to target installation
  4. Update all Debian packages from delta (if cluster is running)
  5. Update all container images from delta
  6. Automatically stop and restart the cluster if it was running
`

var upgradeCommandExample = `
  # Full upgrade: Upgrades the cluster to this version
  k2s system upgrade

  # Full upgrade: Skips takeover of existing cluster resources
  k2s system upgrade -s

  # Full upgrade: Deleting downloaded files after upgrade
  k2s system upgrade -d
  
  # Delta update: From extracted delta package
  Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
  cd .\delta
  .\k2s.exe system upgrade
`

const (
	configFileFlagName = "config"
	skipK8sResources   = "skip-resources"
	deleteFiles        = "delete-files"
	proxy              = "proxy"
	defaultProxy       = ""
	skipImagesFlag     = "skip-images"
	backupDir          = "backup-dir"
	force              = "force"
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
	cmd.Flags().BoolP(skipImagesFlag, "i", false, "Skip takeover of container images from old cluster to new cluster")
	cmd.Flags().BoolP(force, "f", false, "Forces the upgrade, even if the previous and current versions are not consecutive")
	cmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func upgradeCluster(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Analyze current cluster and check prerequisites ...")

	showLog, err := cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	runtimeConfig, err := readConfigLegacyAware(context.Config())
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

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	psCmd := createUpgradeCommand(cmd)

	slog.Debug("PS command created", "command", psCmd)

	outputWriter := common.NewPtermWriter()

	switchToUpgradeLogFile(showLog, context.Logger())

	psErr := powershell.ExecutePs(psCmd, outputWriter)

	switchToDefaultLogFile(showLog, context.Logger())

	if psErr != nil {
		return psErr
	}

	if outputWriter.ErrorOccurred {
		return common.CreateSystemUnableToUpgradeCmdFailure()
	}

	cmdSession.Finish()

	return nil
}

func readConfigLegacyAware(k2sConfig *cconfig.K2sConfig) (*cconfig.K2sRuntimeConfig, error) {
	slog.Info("Trying to read the config file", "config-dir", k2sConfig.Host().K2sSetupConfigDir())

	runtimeConfig, err := config.ReadRuntimeConfig(k2sConfig.Host().K2sSetupConfigDir())
	if err != nil {
		if !errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return nil, err
		}

		slog.Info("Config file not found, trying to read the config file from legacy dir", "legacy-dir", k2sConfig.Host().KubeConfig().CurrentDir())

		runtimeConfig, err = config.ReadRuntimeConfig(k2sConfig.Host().KubeConfig().CurrentDir())
		if err != nil {
			return nil, err
		}

		if err := copyLegacyConfigFile(k2sConfig.Host().KubeConfig().CurrentDir(), k2sConfig.Host().K2sSetupConfigDir()); err != nil {
			return nil, err
		}
	}

	slog.Info("Config file read")

	return runtimeConfig, nil
}

func copyLegacyConfigFile(legacyDir string, targetDir string) error {
	slog.Info("Copying config file from legacy dir to target dir", "legacy-dir", legacyDir, "target-dir", targetDir)

	if err := os.MkdirAll(targetDir, fs.ModePerm); err != nil {
		return err
	}

	source := filepath.Join(legacyDir, definitions.K2sRuntimeConfigFileName)
	target := filepath.Join(targetDir, definitions.K2sRuntimeConfigFileName)

	return kos.CopyFile(source, target)
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
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImagesFlag).Value.String())
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
	force, _ := strconv.ParseBool(cmd.Flags().Lookup(force).Value.String())
	if force {
		psCmd += " -Force"
	}
	return psCmd
}

func switchToUpgradeLogFile(showLog bool, logger *logging.Slogger) {
	upgradeLogFilePath := bl.GlobalLogFilePath() + "_cli_upgrade_" + time.Now().Format("2006-01-02_15-04-05")

	slog.Debug("Switching temporary to CLI log file", "path", upgradeLogFilePath)

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
