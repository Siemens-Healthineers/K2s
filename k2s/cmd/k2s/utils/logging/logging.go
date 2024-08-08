// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"log/slog"

	"github.com/samber/lo"
	slogmulti "github.com/samber/slog-multi"
	base "github.com/siemens-healthineers/k2s/internal/logging"
)

// SlogHandler extends slog.Handler interface for e.g. log file sync/close
type SlogHandler interface {
	slog.Handler
	Flush()
	Close()
}

type HandlerBuilder func(levelVar *slog.LevelVar) SlogHandler

type Slogger struct {
	Logger   *slog.Logger
	levelVar *slog.LevelVar
	handlers []SlogHandler
}

// NewSlogger creates a new logger with the default slog logger attached
func NewSlogger() *Slogger {
	return &Slogger{
		handlers: []SlogHandler{},
		levelVar: new(slog.LevelVar),
		Logger:   slog.Default(),
	}
}

/*
SetHandlers flushes and closes existing handlers and replaces them with the given handlers

Example:

	logger.SetHandlers(logging.NewFileHandler("log.file"), logging.NewCliHandler())
*/
func (l *Slogger) SetHandlers(handlerBuilders ...HandlerBuilder) *Slogger {
	l.Flush()
	l.Close()

	l.handlers = lo.Map(handlerBuilders, func(b HandlerBuilder, _ int) SlogHandler {
		return b(l.levelVar)
	})

	slogHandlers := lo.Map(l.handlers, func(h SlogHandler, _ int) slog.Handler {
		return h.(slog.Handler)
	})

	l.Logger = slog.New(slogmulti.Fanout(slogHandlers...))

	return l
}

// SetGlobally sets the slog logger as global default
func (l *Slogger) SetGlobally() *Slogger {
	slog.SetDefault(l.Logger)
	return l
}

// Flush flushes existing handlers
func (l *Slogger) Flush() {
	lo.ForEach(l.handlers, func(h SlogHandler, _ int) {
		h.Flush()
	})
}

// Close closes existing handlers
func (l *Slogger) Close() {
	lo.ForEach(l.handlers, func(h SlogHandler, _ int) {
		h.Close()
	})
}

// SetVerbosity sets the given verbosity
func (l *Slogger) SetVerbosity(verbosity string) error {
	return base.SetVerbosity(verbosity, l.levelVar)
}
