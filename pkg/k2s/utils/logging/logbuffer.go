// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"errors"
	"strings"

	"k8s.io/klog/v2"
)

type BufferConfig struct {
	Limit     uint
	FlushFunc func(args ...any)
}

type logBuffer struct {
	buffer []string
	config BufferConfig
}

func NewLogBuffer(config BufferConfig) (*logBuffer, error) {
	if config.Limit == 0 {
		return nil, errors.New("buffer limit must be greater than 0")
	}
	if config.FlushFunc == nil {
		return nil, errors.New("flush function must not be nil")
	}

	return &logBuffer{
		buffer: []string{},
		config: config,
	}, nil
}

func (e *logBuffer) Log(line string) {
	e.buffer = append(e.buffer, line)

	if len(e.buffer) >= int(e.config.Limit) {
		klog.V(8).InfoS("log buffer limit reached, flushing the buffer", "limit", e.config.Limit)

		e.Flush()
	}
}

func (e *logBuffer) Flush() {
	if len(e.buffer) > 0 {
		e.config.FlushFunc(squash(e.buffer))

		e.buffer = []string{}
	}
}

func squash(lines []string) string {
	return strings.Join(lines, "\n")
}
