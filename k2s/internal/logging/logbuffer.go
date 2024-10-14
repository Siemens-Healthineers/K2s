// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
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

type LogBuffer struct {
	buffer []string
	config BufferConfig
	lock   sync.Mutex
}

func NewLogBuffer(config BufferConfig) (*LogBuffer, error) {
	if config.Limit == 0 {
		return nil, errors.New("buffer limit must be greater than 0")
	}
	if config.FlushFunc == nil {
		return nil, errors.New("flush function must not be nil")
	}

	return &LogBuffer{
		config: config,
	}, nil
}

func (e *LogBuffer) Log(line string) {
	e.lock.Lock()
	defer e.lock.Unlock()

	e.buffer = append(e.buffer, line)

	if len(e.buffer) >= int(e.config.Limit) {
		slog.Debug("Log buffer limit reached", "limit", e.config.Limit)

		e.flush()
	}
}

func (e *LogBuffer) Flush() {
	e.lock.Lock()
	defer e.lock.Unlock()

	if len(e.buffer) > 0 {
		e.flush()
	}
}

func (e *LogBuffer) flush() {
	slog.Debug("Flushing the buffer", "len", len(e.buffer))

	e.config.FlushFunc(e.buffer)

	e.buffer = nil
}
