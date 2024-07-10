// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"fmt"
	"log"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/common"
	base "github.com/siemens-healthineers/k2s/internal/logging"
)

type FileHandler struct {
	slog.JSONHandler
	logFile *os.File
}

// DefaultLogFilePath returns the default path of the CLI's log file
func DefaultLogFilePath() string {
	return filepath.Join(base.RootLogDir(), "cli", fmt.Sprintf("%s.exe.log", common.CliName))
}

// NewFileHandler initializes the log file at the given path and creates an slog handler logging to this file
func NewFileHandler(filePath string) HandlerBuilder {
	return func(levelVar *slog.LevelVar) SlogHandler {
		logFile := base.InitializeLogFile(filePath)
		options := &slog.HandlerOptions{
			Level:       levelVar,
			AddSource:   true,
			ReplaceAttr: base.ShortenSourceAttribute,
		}
		jsonHandler := slog.NewJSONHandler(logFile, options)

		return &FileHandler{
			JSONHandler: *jsonHandler,
		}
	}
}

// Flush writes pending changes to the log file
func (h *FileHandler) Flush() {
	if h.logFile == nil {
		return
	}

	if err := h.logFile.Sync(); err != nil {
		log.Fatal(err)
	}
}

// Close closes the log file and removes the file handle
func (h *FileHandler) Close() {
	if h.logFile == nil {
		return
	}

	if err := h.logFile.Close(); err != nil {
		log.Fatal(err)
	}

	h.logFile = nil
}
