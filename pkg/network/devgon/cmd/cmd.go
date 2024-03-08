//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package cmd

import (
	"devgon/cmd/install"
	"devgon/cmd/remove"
	"devgon/cmd/version"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	verbosityFlagName      = "verbosity"
	verbosityFlagShorthand = "v"
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

	verbosity := ""
	levelVar := setDefaultLogger()

	bindVerbosityFlag(&verbosity, cmd.PersistentFlags())

	cmd.PersistentPreRunE = func(cmd *cobra.Command, args []string) error {
		return setVerbosityLevel(verbosity, levelVar)
	}

	return cmd
}

// TODO: put in logging package
// TODO: return custom type to allow verbosity setting
func setDefaultLogger() *slog.LevelVar {
	var levelVar = new(slog.LevelVar)
	options := defaultHandlerOptions(levelVar)
	handler := slog.NewTextHandler(os.Stderr, options)
	logger := slog.New(handler)

	slog.SetDefault(logger)

	return levelVar
}

// TODO: put in logging package
func setVerbosityLevel(verbosity string, levelVar *slog.LevelVar) error {
	level, err := parseLevel(verbosity)
	if err != nil {
		return err
	}

	levelVar.Set(level)

	slog.Info("logger level set", "level", level)

	return nil
}

// TODO: put in logging package
func defaultHandlerOptions(level *slog.LevelVar) *slog.HandlerOptions {
	return &slog.HandlerOptions{
		Level:       level,
		AddSource:   true,
		ReplaceAttr: replaceSourceFilePath}
}

// TODO: put in cmd package
func bindVerbosityFlag(verbosity *string, flagSet *pflag.FlagSet) {
	flagSet.StringVarP(verbosity, verbosityFlagName, verbosityFlagShorthand, levelToString(slog.LevelInfo), generateLogLevelHelp())
}

// TODO: put in logging package
func replaceSourceFilePath(_ []string, attribute slog.Attr) slog.Attr {
	if attribute.Key == slog.SourceKey {
		source := attribute.Value.Any().(*slog.Source)
		source.File = filepath.Base(source.File)
	}
	return attribute
}

// TODO: put in logging package
func parseLevel(input string) (slog.Level, error) {
	var level slog.Level

	if err := level.UnmarshalText([]byte(input)); err != nil {
		parsedLevel, intErr := strconv.Atoi(input)
		if intErr != nil {
			return level, fmt.Errorf("cannot convert '%s' to log level: %w", input, errors.Join(err, intErr))
		}
		level = slog.Level(parsedLevel)
	}

	return level, nil
}

// TODO: put in cmd package
func generateLogLevelHelp() string {
	debug := levelToString(slog.LevelDebug)
	info := levelToString(slog.LevelInfo)
	warn := levelToString(slog.LevelWarn)
	err := levelToString(slog.LevelError)

	return "log level verbosity, either pre-defined levels, integer values or a combination of both.\n" +
		fmt.Sprintf("Pre-defined levels: %s = %d | %s = %d | %s = %d | %s = %d\n", debug, slog.LevelDebug, info, slog.LevelInfo, warn, slog.LevelWarn, err, slog.LevelError) +
		fmt.Sprintf("- e.g. '-v %s'	-> %s\n", debug, debug) +
		fmt.Sprintf("- e.g. '-v %d'	-> %s\n", slog.LevelWarn, warn) +
		fmt.Sprintf("- e.g. '-v %s+4'	-> %s\n", debug, info) +
		fmt.Sprintf("- e.g. '-v %s-8'	-> %s\n", err, info) +
		fmt.Sprintf("- e.g. '-v %s+2'	-> %d (between %s and %s)\n", warn, slog.LevelWarn+2, warn, err)
}

// TODO: put in logging package
func levelToString(level slog.Level) string {
	return strings.ToLower(level.String())
}
