package json

type Addons struct {
	EnabledAddons  []string `json:"enabledAddons"`
	DisabledAddons []string `json:"disabledAddons"`
}

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

func (jp JsonPrinter) PrintJson(addons *Addons) error {
	bytes, err := jp.jsonMarshaller.MarshalIndent(addons)
	if err != nil {
		return err
	}

	jp.terminalPrinter.Println(string(bytes))

	return nil
}
