// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/host"
)

func SetVerbosity(verbosity string, levelVar *slog.LevelVar) error {
	level, err := parseLevel(verbosity)
	if err != nil {
		return err
	}

	levelVar.Set(level)

	slog.Info("logger level set", "level", level)

	return nil
}

func RootLogDir() string {
	return filepath.Join(host.SystemDrive(), "var", "log")
}

func LevelToLowerString(level slog.Level) string {
	return strings.ToLower(level.String())
}

func ReplaceSourceFilePath(_ []string, attribute slog.Attr) slog.Attr {
	if attribute.Key == slog.SourceKey {
		source := attribute.Value.Any().(*slog.Source)
		source.File = filepath.Base(source.File)
	}
	return attribute
}

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

// InitializeLogFile creates the log directory and file if not existing
// Returns the log file handle
// path - The log file path
func InitializeLogFile(path string) *os.File {
	dir := filepath.Dir(path)

	if err := host.CreateDirIfNotExisting(dir); err != nil {
		panic(err)
	}

	var err error
	logFile, err := os.OpenFile(
		path,
		os.O_APPEND|os.O_CREATE|os.O_WRONLY,
		os.ModePerm,
	)
	if err != nil {
		panic(err)
	}

	return logFile
}
