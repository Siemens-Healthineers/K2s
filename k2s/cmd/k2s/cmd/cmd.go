// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cmd

import (
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons"
	im "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image"
	in "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/start"
	stat "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	stop "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/stop"
	sys "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system"
	un "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/uninstall"
	ve "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/version"
	"github.com/siemens-healthineers/k2s/cmd/k2s/common"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/logging"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

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
			return logging.SetVerbosity(verbosity, levelVar)
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
	persistentFlags.BoolP(params.OutputFlagName, params.OutputFlagShorthand, false, params.OutputFlagUsage)
	persistentFlags.StringVarP(&verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, logging.LevelToLowerString(slog.LevelWarn), cli.VerbosityFlagHelp())

	return cmd, nil
}