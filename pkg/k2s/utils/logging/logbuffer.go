// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"errors"
	"log/slog"
	"sync"
)

type BufferConfig struct {
	Limit     uint
	FlushFunc func(buffer []string)
}

type logBuffer struct {
	buffer []string
	config BufferConfig
	lock   sync.Mutex
}

func NewLogBuffer(config BufferConfig) (*logBuffer, error) {
	if config.Limit == 0 {
		return nil, errors.New("buffer limit must be greater than 0")
	}
	if config.FlushFunc == nil {
		return nil, errors.New("flush function must not be nil")
	}

	return &logBuffer{
		config: config,
	}, nil
}

func (e *logBuffer) Log(line string) {
	e.lock.Lock()
	defer e.lock.Unlock()

	e.buffer = append(e.buffer, line)

	if len(e.buffer) >= int(e.config.Limit) {
		slog.Debug("Log buffer limit reached", "limit", e.config.Limit)

		e.flush()
	}
}

func (e *logBuffer) Flush() {
	e.lock.Lock()
	defer e.lock.Unlock()

	if len(e.buffer) > 0 {
		e.flush()
	}
}

func (e *logBuffer) flush() {
	slog.Debug("Flushing the buffer", "len", len(e.buffer))

	e.config.FlushFunc(e.buffer)

	e.buffer = nil
}
