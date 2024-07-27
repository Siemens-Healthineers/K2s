// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package terminalprinter

import (
	"log/slog"
)

type SlogPrinter struct{}

func (l *SlogPrinter) LogInfo(message string) {
	slog.Info(message)
}
