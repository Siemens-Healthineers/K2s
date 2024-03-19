// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
	"fmt"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintCyanFg(text string) string
}

type PrintSetupInfo struct {
	Version   string `json:"version"`
	Name      string `json:"name"`
	LinuxOnly bool   `json:"linuxOnly"`
}

type SetupInfoPrinter struct {
	terminalPrinter TerminalPrinter
}

func NewSetupInfoPrinter(terminalPrinter TerminalPrinter) SetupInfoPrinter {
	return SetupInfoPrinter{
		terminalPrinter: terminalPrinter,
	}
}

func (s SetupInfoPrinter) PrintSetupInfo(setupInfo *PrintSetupInfo) (bool, error) {
	if setupInfo == nil {
		return false, errors.New("no setup information retrieved")
	}

	typeText := string(setupInfo.Name)
	if setupInfo.LinuxOnly {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup: '%s', Version: '%s'", s.terminalPrinter.PrintCyanFg(typeText), s.terminalPrinter.PrintCyanFg(setupInfo.Version))

	s.terminalPrinter.Println(printText)

	return true, nil
}
