// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setuptype

import (
	"fmt"
	"k2s/cmd/status/load"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintWarning(m ...any)
	PrintCyanFg(text string) string
}

type SetupTypePrinter struct {
	terminalPrinter TerminalPrinter
}

func NewSetupTypePrinter(terminalPrinter TerminalPrinter) SetupTypePrinter {
	return SetupTypePrinter{terminalPrinter: terminalPrinter}
}

func (s SetupTypePrinter) PrintSetupType(setupType load.SetupType) bool {
	if setupType.ValidationError != "" {
		prefix := ""

		if setupType.Name != "" {
			prefix = fmt.Sprintf("Found '%s' setup type, but: ", setupType.Name)
		}

		warning := fmt.Sprintf("%s%s", prefix, setupType.ValidationError)

		s.terminalPrinter.PrintWarning(warning)
		s.terminalPrinter.Println()

		return false
	}

	typeText := setupType.Name
	if setupType.LinuxOnly {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup type: '%s', Version: '%s'", s.terminalPrinter.PrintCyanFg(typeText), s.terminalPrinter.PrintCyanFg(setupType.Version))

	s.terminalPrinter.Println(printText)

	return true
}
