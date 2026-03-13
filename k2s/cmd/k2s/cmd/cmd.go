// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cmd

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons"
	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	im "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image"
	in "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/start"
	stat "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	stop "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/stop"
	sys "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system"
	un "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/uninstall"
	ve "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/version"
	"github.com/siemens-healthineers/k2s/cmd/k2s/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/logging"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/json"
	bl "github.com/siemens-healthineers/k2s/internal/logging"

	"github.com/spf13/cobra"
)

func CreateRootCmd(logger *logging.Slogger) (*cobra.Command, error) {
	verbosity := bl.LevelToLowerString(slog.LevelInfo)
	showLog := false

	cmd := &cobra.Command{
		Use:               common.CliName,
		Short:             "k2s – command-line tool to interact with the K2s cluster",
		SilenceErrors:     true,
		SilenceUsage:      true,
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if err := logger.SetVerbosity(verbosity); err != nil {
				return err
			}

			fileHandler := logging.NewFileHandler(bl.GlobalLogFilePath())

			// Log CLI invocation to file only (before adding CLI handler)
			logger.SetHandlers(fileHandler).SetGlobally()
			slog.Info("<*********************************>")
			slog.Info("CLI invocation", "cmd", strings.Join(os.Args, " "))
			slog.Debug("log level set", "level", verbosity)

			// Set up full handler chain including CLI handler if requested
			if showLog {
				logger.SetHandlers(fileHandler, logging.NewCliHandler()).SetGlobally()
			}

			// TODO: always load setup config and determine PS version?

			configDir := utils.InstallDir()
			k2sConfig, err := config.ReadK2sConfig(configDir)
			if err != nil {
				// Config not found at executable directory — check if running from a delta
				// package directory and resolve the actual install dir from setup.json
				actualDir, resolveErr := resolveInstallDirForDelta(configDir)
				if resolveErr == nil && actualDir != configDir {
					slog.Info("Config not found at exe dir, using actual install dir", "exe-dir", configDir, "install-dir", actualDir)
					k2sConfig, err = config.ReadK2sConfig(actualDir)
				}
			}
			if err != nil {
				return err
			}

			slog.Debug("config loaded", "config", k2sConfig)

			cmd.SetContext(context.WithValue(cmd.Context(), cc.ContextKeyCmdContext, cc.NewCmdContext(k2sConfig, logger)))

			return nil
		},
	}

	addonsCmd, err := addons.NewCmd()
	if err != nil {
		return nil, err
	}

	cmd.AddCommand(start.Startk8sCmd)
	cmd.AddCommand(stop.Stopk8sCmd)
	cmd.AddCommand(in.InstallCmd)
	cmd.AddCommand(un.Uninstallk8sCmd)
	cmd.AddCommand(im.ImageCmd)
	cmd.AddCommand(stat.StatusCmd)
	cmd.AddCommand(addonsCmd)
	cmd.AddCommand(ve.VersionCmd)
	cmd.AddCommand(sys.SystemCmd)
	cmd.AddCommand(node.NewCmd())

	persistentFlags := cmd.PersistentFlags()
	persistentFlags.BoolVarP(&showLog, cc.OutputFlagName, cc.OutputFlagShorthand, showLog, cc.OutputFlagUsage)
	persistentFlags.StringVarP(&verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, verbosity, cli.VerbosityFlagHelp())

	return cmd, nil
}

// setupJson is the minimal struct for reading InstallFolder from setup.json.
type setupJson struct {
	InstallFolder string `json:"InstallFolder"`
}

// resolveInstallDirForDelta checks if the executable is running from a delta package
// directory (indicated by delta-manifest.json) and resolves the actual K2s install
// directory from setup.json at the well-known system location.
func resolveInstallDirForDelta(exeDir string) (string, error) {
	deltaManifest := filepath.Join(exeDir, "delta-manifest.json")
	if _, err := os.Stat(deltaManifest); err != nil {
		return exeDir, err
	}

	slog.Info("Delta package detected, resolving actual install directory")

	// Read install folder from setup.json at the well-known ProgramData location,
	// consistent with Start-ClusterUpdate.ps1 behavior
	systemDrive := os.Getenv("SystemDrive")
	if systemDrive == "" {
		systemDrive = "C:"
	}
	setupConfigPath := filepath.Join(systemDrive, "ProgramData", "k2s", "setup.json")

	setup, err := json.FromFile[setupJson](setupConfigPath)
	if err != nil {
		slog.Warn("Could not read setup.json", "path", setupConfigPath, "error", err)
		return exeDir, err
	}

	if setup.InstallFolder == "" {
		slog.Warn("InstallFolder not set in setup.json")
		return exeDir, nil
	}

	slog.Info("Resolved actual install directory from setup.json", "install-dir", setup.InstallFolder)
	return setup.InstallFolder, nil
}
