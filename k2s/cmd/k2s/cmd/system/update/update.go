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
[EXPERIMENTAL] Updates the installed K2s cluster to a newer version using an in-place update with a delta package.

⚠  This command must be executed from within the extracted delta package directory, e.g.:
   1. Extract the delta package: Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
   2. Navigate to the extracted directory: cd .\delta
   3. Run the update: .\k2s.exe system update

The following tasks will be executed:
1. Detect delta package root (current directory with delta-manifest.json)
2. Detect target installation folder (from setup.json)
3. Update all Windows executables and scripts from the delta package to the target installation
4. Update all Debian packages from the delta package (if cluster is running)
5. Update all container images from the delta package
6. Automatically stop and restart the cluster if it was running

By default all existing cluster resources (e.g. namespaces, deployments, services, etc.) will remain in the updated cluster.
`

var updateCommandExample = `
  # Extract and prepare the delta package
  Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
  cd .\delta
  
  # Update the cluster from the extracted delta package
  .\k2s.exe system update

`

const (
	// No longer using delta-package flag
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
	// No flags needed - delta package is detected from current directory
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
	// No delta package parameter needed - PowerShell script detects from current directory
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
