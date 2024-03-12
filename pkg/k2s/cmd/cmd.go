// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cmd

import (
	"base/cli"
	"base/logging"
	"k2s/cmd/addons"
	im "k2s/cmd/image"
	in "k2s/cmd/install"
	"k2s/cmd/start"
	stat "k2s/cmd/status"
	stop "k2s/cmd/stop"
	sys "k2s/cmd/system"
	un "k2s/cmd/uninstall"
	ve "k2s/cmd/version"
	"k2s/common"
	"log/slog"

	"k2s/cmd/params"

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
