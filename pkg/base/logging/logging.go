//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package logging

import (
	"base/system"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"
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
	return filepath.Join(system.SystemDrive(), "var", "log")
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
