// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cmd

import (
	"context"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons"
	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	im "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image"
	in "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/start"
	stat "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	stop "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/stop"
	sys "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system"
	un "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/uninstall"
	ve "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/version"
	"github.com/siemens-healthineers/k2s/cmd/k2s/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/logging"

	"github.com/spf13/cobra"
)

func CreateRootCmd(levelVar *slog.LevelVar) (*cobra.Command, error) {
	verbosity := ""
	cmd := &cobra.Command{
		Use:               common.CliName,
		Short:             "k2s – command-line tool to interact with the K2s cluster",
		SilenceErrors:     true,
		SilenceUsage:      true,
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if err := logging.SetVerbosity(verbosity, levelVar); err != nil {
				return err
			}

			// TODO: always load setup config and determine PS version?
			config, err := config.LoadConfig(utils.InstallDir())
			if err != nil {
				return err
			}

			slog.Debug("config loaded", "config", config)

			cmd.SetContext(context.WithValue(cmd.Context(), cc.ContextKeyConfigDir, config.Host.KubeConfigDir))

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

	persistentFlags := cmd.PersistentFlags()
	persistentFlags.BoolP(cc.OutputFlagName, cc.OutputFlagShorthand, false, cc.OutputFlagUsage)
	persistentFlags.StringVarP(&verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, logging.LevelToLowerString(slog.LevelWarn), cli.VerbosityFlagHelp())

	return cmd, nil
}
