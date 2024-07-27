// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package terminalprinter

import "github.com/pterm/pterm"

type UserFriendlyPrinter struct {
	CurrentSpinner *pterm.SpinnerPrinter
}

func (l *UserFriendlyPrinter) LogInfo(message string) {
	pterm.Info.Println(message)
}

func (l *UserFriendlyPrinter) StartSpinnerMsg(m ...any) {
	pSpinner, _ := pterm.DefaultSpinner.WithRemoveWhenDone().Start(m...)
	l.CurrentSpinner = pSpinner
}

func (l *UserFriendlyPrinter) StopSpinner() {
	if l.CurrentSpinner != nil {
		l.CurrentSpinner.Stop()
	}
}
