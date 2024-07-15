// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"log"
	"log/slog"
	"os"

	base "github.com/siemens-healthineers/k2s/internal/logging"
)

type FileHandler struct {
	slog.JSONHandler
	logFile *os.File
}

const (
	componentAttributeName = "component"
	componentName          = "k2s.exe"
)

// NewFileHandler initializes the log file at the given path and creates an slog handler logging to this file
func NewFileHandler(filePath string) HandlerBuilder {
	return func(levelVar *slog.LevelVar) SlogHandler {
		logFile := base.InitializeLogFile(filePath)
		options := &slog.HandlerOptions{
			Level:       levelVar,
			AddSource:   true,
			ReplaceAttr: base.ShortenSourceAttribute,
		}
		componentAttribute := slog.String(componentAttributeName, componentName)
		jsonHandler := slog.NewJSONHandler(logFile, options).WithAttrs([]slog.Attr{componentAttribute}).(*slog.JSONHandler)

		return &FileHandler{
			JSONHandler: *jsonHandler,
			logFile:     logFile,
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
