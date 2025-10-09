// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package update

import (
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
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

var updateCommandShortDescription = "[EXPERIMENTAL] Update the installed K2s cluster to a newer version using an in-place update with a delta package"

var updateCommandLongDescription = `
Updates the installed K2s cluster to a newer version using an in-place update with a delta package.

⚠  This command must be called within the folder containing the new K2s version, e.g. '<new-version-dir>\k2s.exe system update'

The following tasks will be executed:
1. Update all windows executables and scripts from the delta package
2. Update all debian packages from the delta package
3. Update all containers images from the delta package

By default all existing cluster resources (e.g. namespaces, deployments, services, etc.) will remain also in the new cluster.
`

var updateCommandExample = `
  # Updates the cluster using a delta package
  k2s system update -f .\k2s-delta-<version1>-to-<version2>.zip

`

const (
	deltaPackageFlagName   = "delta-package"
)

var UpdateCmd = &cobra.Command{
	Use:     "update",
	Short:   updateCommandShortDescription,
	Long:    updateCommandLongDescription,
	RunE:    updateCluster,
	Example: updateCommandExample,
}

func init() {
	AddInitFlags(UpdateCmd)
}

func AddInitFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(deltaPackageFlagName, "f", "", "Path to the delta package to use for the update")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func updateCluster(cmd *cobra.Command, args []string) error {
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

	psCmd := createUpdateCommand(cmd)

	slog.Debug("PS command created", "command", psCmd)

	outputWriter := common.NewPtermWriter()

	switchToUpdateLogFile(showLog, context.Logger())

	psErr := powershell.ExecutePs(psCmd, outputWriter)

	switchToDefaultLogFile(showLog, context.Logger())

	if psErr != nil {
		return psErr
	}

	if outputWriter.ErrorOccurred {
		return common.CreateSystemUnableToUpdateCmdFailure()
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

func createUpdateCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "update", "Start-ClusterUpdate.ps1"))
	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		slog.Debug("Param", "name", f.Name, "value", f.Value)
	})
	config := cmd.Flags().Lookup(deltaPackageFlagName).Value.String()
	if len(config) > 0 {
		psCmd += " -DeltaPackage " + config
	}
	return psCmd
}

func switchToUpdateLogFile(showLog bool, logger *logging.Slogger) {
	updateLogFilePath := bl.GlobalLogFilePath() + "_cli_update_" + time.Now().Format("2006-01-02_15-04-05")

	slog.Debug("Switching temporary to CLI update log file", "path", updateLogFilePath)

	setLogger(showLog, logger, updateLogFilePath)
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
