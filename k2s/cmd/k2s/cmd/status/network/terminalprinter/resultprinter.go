// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package terminalprinter

type InfoLogger interface {
	LogInfo(message string)
}

type SpinnerLogger interface {
	StartSpinnerMsg(m ...any)
	StopSpinner()
}
