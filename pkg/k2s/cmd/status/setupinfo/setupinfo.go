// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"errors"
	"fmt"
	"k2s/cmd/status/defs"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintInfoln(m ...any)
	PrintWarning(m ...any)
	PrintCyanFg(text string) string
}

type SetupInfoPrinter struct {
	terminalPrinter          TerminalPrinter
	printNotInstalledMsgFunc func()
}

func NewSetupInfoPrinter(terminalPrinter TerminalPrinter, printNotInstalledMsgFunc func()) SetupInfoPrinter {
	return SetupInfoPrinter{
		terminalPrinter:          terminalPrinter,
		printNotInstalledMsgFunc: printNotInstalledMsgFunc}
}

func (s SetupInfoPrinter) PrintSetupInfo(setupInfo defs.SetupInfo) (bool, error) {
	if setupInfo.ValidationError != nil {
		switch *setupInfo.ValidationError {
		case string(defs.ErrNotInstalled):
			s.printNotInstalledMsgFunc()
		case string(defs.ErrNoClusterAvailable):
			if setupInfo.Name == nil {
				s.terminalPrinter.PrintWarning("The cluster is not available for an unknown reason. Consider re-installing K2s")
			} else {
				s.terminalPrinter.PrintInfoln("There is no cluster available for '%s' setup", *setupInfo.Name)
			}
		default:
			s.terminalPrinter.PrintWarning("The setup information seems to be invalid: '%s'", *setupInfo.ValidationError)
		}

		s.terminalPrinter.Println()

		return false, nil
	}

	if setupInfo.LinuxOnly == nil {
		return false, errors.New("no Linux-only information retrieved")
	}

	if setupInfo.Name == nil {
		return false, errors.New("no setup name retrieved")
	}

	if setupInfo.Version == nil {
		return false, errors.New("no setup version retrieved")
	}

	typeText := *setupInfo.Name
	if *setupInfo.LinuxOnly {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup: '%s', Version: '%s'", s.terminalPrinter.PrintCyanFg(typeText), s.terminalPrinter.PrintCyanFg(*setupInfo.Version))

	s.terminalPrinter.Println(printText)

	return true, nil
}
