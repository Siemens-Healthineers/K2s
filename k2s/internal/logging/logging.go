// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package logging

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

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

	if err := os.MkdirAll(dir, fs.ModePerm); err != nil {
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

// CleanLogDir removes all files in the given directory that are older than the given age
// It considers only files in the given directory, not in sub-directories
func CleanLogDir(dir string, maxFileAge time.Duration) error {
	files, err := kos.FilesInDir(dir)
	if err != nil {
		return fmt.Errorf("failed to list files in log dir '%s': %w", dir, err)
	}

	slog.Debug("Found file in dir", "count", len(files), "dir", dir)

	err = files.OlderThan(maxFileAge).JoinPathsWith(dir).Remove()
	if err != nil {
		return fmt.Errorf("failed to delete outdated files in log dir '%s': %w", dir, err)
	}
	return nil
}

// SetupDefaultFileLogger sets up the default slog logger to log to the given file, removing it first if it exists
func SetupDefaultFileLogger(logDir, logFileName string, level slog.Level, args ...any) (*os.File, error) {
	logFilePath := filepath.Join(logDir, logFileName)
	if kos.PathExists(logFilePath) {
		if err := kos.RemovePaths(logFilePath); err != nil {
			return nil, fmt.Errorf("cannot remove log file '%s': %s", logFilePath, err)
		}
	}

	logFile := InitializeLogFile(logFilePath)
	loggerOptions := &slog.HandlerOptions{Level: level}
	textHandler := slog.NewTextHandler(logFile, loggerOptions)
	logger := slog.New(textHandler).With(args...)

	slog.SetDefault(logger)

	return logFile, nil
}

func LogExecutionTime(start time.Time, functionName string) {
	duration := time.Since(start)

	slog.Info("Execution finished", "function", functionName, "duration", duration)
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
