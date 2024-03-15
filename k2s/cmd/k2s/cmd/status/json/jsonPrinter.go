// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package json

type TerminalPrinter interface {
	Println(m ...any)
}

type JsonPrinter struct {
	terminalPrinter   TerminalPrinter
	marshalIndentFunc func(data any) ([]byte, error)
}

func NewJsonPrinter(terminalPrinter TerminalPrinter, marshalIndentFunc func(data any) ([]byte, error)) JsonPrinter {
	return JsonPrinter{
		terminalPrinter:   terminalPrinter,
		marshalIndentFunc: marshalIndentFunc,
	}
}

func (jp JsonPrinter) PrintJson(status any) error {
	bytes, err := jp.marshalIndentFunc(status)
	if err != nil {
		return err
	}

	jp.terminalPrinter.Println(string(bytes))

	return nil
}
