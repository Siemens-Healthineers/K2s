package json

import "k2s/cmd/status/load"

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

func (jp JsonPrinter) PrintJson(status *load.Status) error {
	bytes, err := jp.jsonMarshaller.MarshalIndent(status)
	if err != nil {
		return err
	}

	jp.terminalPrinter.Println(string(bytes))

	return nil
}
