// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package json

type TerminalPrinter interface {
	Println(m ...any)
}

type JsonMarshaller interface {
	MarshalIndent(data any) ([]byte, error)
}

type JsonPrinter struct {
	terminalPrinter TerminalPrinter
	jsonMarshaller  JsonMarshaller
}

func NewJsonPrinter(terminalPrinter TerminalPrinter, jsonMarshaller JsonMarshaller) JsonPrinter {
	return JsonPrinter{
		terminalPrinter: terminalPrinter,
		jsonMarshaller:  jsonMarshaller,
	}
}

func (jp JsonPrinter) PrintJson(status any) error {
	bytes, err := jp.jsonMarshaller.MarshalIndent(status)
	if err != nil {
		return err
	}

	jp.terminalPrinter.Println(string(bytes))

	return nil
}
