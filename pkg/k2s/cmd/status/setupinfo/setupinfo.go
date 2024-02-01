// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
	"fmt"
	si "k2s/setupinfo"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintCyanFg(text string) string
}

type SetupInfoPrinter struct {
	terminalPrinter TerminalPrinter
}

func NewSetupInfoPrinter(terminalPrinter TerminalPrinter) SetupInfoPrinter {
	return SetupInfoPrinter{
		terminalPrinter: terminalPrinter,
	}
}

// TODO: move load and print to setupinfo package (see addons package)
func (s SetupInfoPrinter) PrintSetupInfo(setupInfo si.SetupInfo) (bool, error) {
	if setupInfo.LinuxOnly == nil {
		return false, errors.New("no Linux-only information retrieved")
	}

	if setupInfo.Name == nil {
		return false, errors.New("no setup name retrieved")
	}

	if setupInfo.Version == nil {
		return false, errors.New("no setup version retrieved")
	}

	typeText := string(*setupInfo.Name)
	if *setupInfo.LinuxOnly {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup: '%s', Version: '%s'", s.terminalPrinter.PrintCyanFg(typeText), s.terminalPrinter.PrintCyanFg(*setupInfo.Version))

	s.terminalPrinter.Println(printText)

	return true, nil
}
