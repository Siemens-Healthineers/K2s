// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package terminalprinter

func NewPrinterContext(outputType string) *PrinterContext {
	var printerContext *PrinterContext
	if outputType == "json" {
		slogPrinter := &SlogPrinter{}
		printerContext = NewLoggerContext(slogPrinter, nil)
	} else {
		userFriendlyLogger := &UserFriendlyPrinter{}
		printerContext = NewLoggerContext(userFriendlyLogger, userFriendlyLogger)
	}

	return printerContext
}
