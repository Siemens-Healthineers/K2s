// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
)

const ErrNotRunningMsg = "not-running"

var ErrNotRunning = errors.New(ErrNotRunningMsg)

func IsErrNotRunning(err string) bool {
	return err == ErrNotRunningMsg
}
