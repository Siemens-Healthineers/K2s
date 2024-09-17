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
	kos "github.com/siemens-healthineers/k2s/internal/os"
)

// RootLogDir returns K2s' central log directory
func RootLogDir() string {
	return filepath.Join(host.SystemDrive(), "var", "log")
}

// GlobalLogFilePath returns K2s' global log file path
func GlobalLogFilePath() string {
	return filepath.Join(RootLogDir(), "k2s.log")
}

// InitializeLogFile creates the log directory and file if not existing
// Returns the log file handle
// path - The log file path
func InitializeLogFile(path string) *os.File {
	dir := filepath.Dir(path)

	if err := kos.CreateDirIfNotExisting(dir); err != nil {
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

// SetVerbosity sets the given verbosity on the log level variable after successful parsing
func SetVerbosity(verbosity string, levelVar *slog.LevelVar) error {
	level, err := parseLevel(verbosity)
	if err != nil {
		return err
	}

	levelVar.Set(level)

	return nil
}

// LevelToLowerString stringifies the given log level.
// The result can be parsed back to slog.Level
func LevelToLowerString(level slog.Level) string {
	return strings.ToLower(level.String())
}

// ShortenSourceAttribute replaces the full source file path with the file name and removes the function completely since the source line number gets logged as well
func ShortenSourceAttribute(_ []string, attribute slog.Attr) slog.Attr {
	if attribute.Key == slog.SourceKey {
		source := attribute.Value.Any().(*slog.Source)
		source.File = filepath.Base(source.File)
		source.Function = ""
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
