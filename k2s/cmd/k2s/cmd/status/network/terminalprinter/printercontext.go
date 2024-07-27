// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package terminalprinter

type PrinterContext struct {
	infoLogger    InfoLogger
	spinnerLogger SpinnerLogger
}

func NewLoggerContext(infoLogger InfoLogger, spinnerLogger SpinnerLogger) *PrinterContext {
	return &PrinterContext{
		infoLogger:    infoLogger,
		spinnerLogger: spinnerLogger,
	}
}

func (c *PrinterContext) LogInfo(message string) {
	c.infoLogger.LogInfo(message)
}

func (c *PrinterContext) StartSpinnerMsg(message string) {
	if c.spinnerLogger != nil {
		c.spinnerLogger.StartSpinnerMsg(message)
	}
}

func (c *PrinterContext) StopSpinner() {
	if c.spinnerLogger != nil {
		c.spinnerLogger.StopSpinner()
	}
}
