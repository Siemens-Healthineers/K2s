// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8sversion

import (
	"errors"
	"fmt"
	"k2s/cmd/status/load"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintCyanFg(text string) string
}

type K8sVersionPrinter struct {
	terminalPrinter TerminalPrinter
}

func NewK8sVersionPrinter(terminalPrinter TerminalPrinter) K8sVersionPrinter {
	return K8sVersionPrinter{terminalPrinter: terminalPrinter}
}

func (p K8sVersionPrinter) PrintK8sVersionInfo(k8sVersionInfo *load.K8sVersionInfo) error {
	if k8sVersionInfo == nil {
		return errors.New("no K8s version info retrieved")
	}

	p.printVersion(k8sVersionInfo.K8sServerVersion, "server")
	p.printVersion(k8sVersionInfo.K8sClientVersion, "client")

	return nil
}

func (p K8sVersionPrinter) printVersion(version string, versionType string) {
	versionText := p.terminalPrinter.PrintCyanFg(version)
	line := fmt.Sprintf("K8s %s version: '%s'", versionType, versionText)

	p.terminalPrinter.Println(line)
}
