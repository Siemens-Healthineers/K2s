//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package cmd

import (
	"devgon/cmd/install"
	"devgon/cmd/remove"
	"devgon/cmd/version"
	"log/slog"
	"os"

	"base/cli"
	"base/logging"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func Create() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "devgon",
		Short: "devgon – command-line tool to replace Microsoft's devcon.exe",
		Long:  ``,

		SilenceErrors: true,
		SilenceUsage:  true,
	}
	cmd.CompletionOptions.DisableDefaultCmd = true
	cmd.AddCommand(install.InstallDeviceCmd)
	cmd.AddCommand(remove.RemoveDeviceCmd)
	cmd.AddCommand(version.VersionCmd)

	var levelVar = new(slog.LevelVar)
	setupLogger(levelVar)

	verbosity := ""
	bindVerbosityFlag(&verbosity, cmd.PersistentFlags())

	cmd.PersistentPreRunE = func(cmd *cobra.Command, args []string) error {
		return logging.SetVerbosity(verbosity, levelVar)
	}

	return cmd
}

func setupLogger(levelVar *slog.LevelVar) {
	options := &slog.HandlerOptions{
		Level:       levelVar,
		AddSource:   true,
		ReplaceAttr: logging.ReplaceSourceFilePath}

	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, options)))
}

// TODO: put in cmd package
func bindVerbosityFlag(verbosity *string, flagSet *pflag.FlagSet) {
	flagSet.StringVarP(verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, logging.LevelToLowerString(slog.LevelInfo), cli.VerbosityFlagHelp())
}
