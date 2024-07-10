// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"log/slog"
	"os"

	"github.com/pterm/pterm"
)

type CliTextHandler struct {
	slog.TextHandler
}

type CliPtermHandler struct {
	pterm.SlogHandler
}

// NewCliPtermHandler creates a new CLI log handler based on pterm package
func NewCliPtermHandler() HandlerBuilder {
	return func(_ *slog.LevelVar) SlogHandler {
		logger := pterm.DefaultLogger.WithMaxWidth(pterm.GetTerminalWidth())
		handler := pterm.NewSlogHandler(logger)

		return &CliPtermHandler{
			SlogHandler: *handler,
		}
	}
}

// NewCliTextHandler creates a new CLI text log handler
func NewCliTextHandler() HandlerBuilder {
	return func(levelVar *slog.LevelVar) SlogHandler {
		options := &slog.HandlerOptions{
			Level:     levelVar,
			AddSource: false,
		}
		textHandler := slog.NewTextHandler(os.Stdout, options)

		return &CliTextHandler{
			TextHandler: *textHandler,
		}
	}
}

// Flush does nothing
func (h *CliTextHandler) Flush() { /*empty*/ }

// Close does nothing
func (h *CliTextHandler) Close() { /*empty*/ }

// Flush does nothing
func (h CliPtermHandler) Flush() { /*empty*/ }

// Close does nothing
func (h CliPtermHandler) Close() { /*empty*/ }
