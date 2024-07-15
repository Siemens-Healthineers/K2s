// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"log/slog"

	"github.com/samber/lo"
	slogmulti "github.com/samber/slog-multi"
)

type SlogHandler interface {
	slog.Handler
	Flush()
	Close()
}

type HandlerBuilder func(levelVar *slog.LevelVar) SlogHandler

type Slogger struct {
	LevelVar *slog.LevelVar
	Logger   *slog.Logger
	handlers []SlogHandler
}

// NewSlogger creates a new logger with the default slog logger attached
func NewSlogger() *Slogger {
	return &Slogger{
		handlers: []SlogHandler{},
		LevelVar: new(slog.LevelVar),
		Logger:   slog.Default(),
	}
}

// SetHandlers flushes and closes existing handlers and replaces them with the given handlers
func (l *Slogger) SetHandlers(handlerBuilders ...HandlerBuilder) *Slogger {
	l.Flush()
	l.Close()

	l.handlers = lo.Map(handlerBuilders, func(b HandlerBuilder, _ int) SlogHandler {
		return b(l.LevelVar)
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
