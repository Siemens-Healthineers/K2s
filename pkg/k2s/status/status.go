// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
)

const (
	ErrNotRunningMsg = "system-not-running"
	ErrRunningMsg    = "system-running"
)

var (
	ErrNotRunning = errors.New(ErrNotRunningMsg)
	ErrRunning    = errors.New(ErrRunningMsg)
)

func IsErrNotRunning(err string) bool {
	return err == ErrNotRunningMsg
}

func IsErrRunning(err string) bool {
	return err == ErrRunningMsg
}
