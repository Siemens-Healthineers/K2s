// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"k8s.io/klog/v2"

	"fmt"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintSuccess(m ...any)
	PrintWarning(m ...any)
	PrintCyanFg(text string) string
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
}

type Spinner interface {
	Stop() error
	Fail(m ...any)
}

type StatusLoader interface {
	LoadAddonStatus(addonName string, addonDirectory string) (*AddonStatus, error)
}

type JsonMarshaller interface {
	MarshalIndent(data any) ([]byte, error)
}

type PropPrinter interface {
	PrintProp(prop AddonStatusProp)
}

type JsonPrinter struct {
	terminalPrinter TerminalPrinter
	jsonMarshaller  JsonMarshaller
	statusLoader    StatusLoader
}

type UserFriendlyPrinter struct {
	terminalPrinter TerminalPrinter
	statusLoader    StatusLoader
	propPrinter     PropPrinter
}

type propPrint struct {
	terminalPrinter TerminalPrinter
}

func NewJsonPrinter(terminalPrinter TerminalPrinter, statusLoader StatusLoader, jsonMarshaller JsonMarshaller) *JsonPrinter {
	return &JsonPrinter{
		terminalPrinter: terminalPrinter,
		statusLoader:    statusLoader,
		jsonMarshaller:  jsonMarshaller,
	}
}

func NewUserFriendlyPrinter(terminalPrinter TerminalPrinter, statusLoader StatusLoader, propPrinters ...PropPrinter) *UserFriendlyPrinter {
	var propPrinter PropPrinter
	if len(propPrinters) > 0 {
		propPrinter = propPrinters[0]
	} else {
		propPrinter = NewPropPrinter(terminalPrinter)
	}

	return &UserFriendlyPrinter{
		terminalPrinter: terminalPrinter,
		statusLoader:    statusLoader,
		propPrinter:     propPrinter,
	}
}

func NewPropPrinter(terminalPrinter TerminalPrinter) *propPrint {
	return &propPrint{
		terminalPrinter: terminalPrinter,
	}
}

func (s *JsonPrinter) PrintStatus(addonName string, addonDirectory string) {
	status, err := s.statusLoader.LoadAddonStatus(addonName, addonDirectory)
	if err != nil {
		klog.Error(err)
		return
	}

	bytes, err := s.jsonMarshaller.MarshalIndent(status)
	if err != nil {
		klog.Error(err)
		return
	}

	s.terminalPrinter.Println(string(bytes))
}

func (s *UserFriendlyPrinter) PrintStatus(addonName string, addonDirectory string) {
	s.terminalPrinter.PrintHeader("ADDON STATUS")

	startResult, err := s.terminalPrinter.StartSpinner("Gathering status information...")
	if err != nil {
		klog.Error(err)
		s.terminalPrinter.Println()
		return
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		klog.Error("could not start operation")
		s.terminalPrinter.Println()
		return
	}

	status, err := s.statusLoader.LoadAddonStatus(addonName, addonDirectory)
	if err != nil {
		klog.Error(err)
		spinner.Fail("Status could not be loaded")
		s.terminalPrinter.Println()
		return
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			klog.Error(err)
			s.terminalPrinter.Println()
		}
	}()

	if status.Error != nil {
		s.terminalPrinter.Println(*status.Error)
		return
	}

	if status.Enabled == nil {
		klog.Error("Enabled/disabled info missing")
		return
	}

	coloredAddonName := s.terminalPrinter.PrintCyanFg(status.Name)

	if !*status.Enabled {
		s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("disabled"))
		return
	}

	s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("enabled"))

	for _, prop := range status.Props {
		s.propPrinter.PrintProp(prop)
	}
}

func (p *propPrint) PrintProp(prop AddonStatusProp) {
	text := p.GetPropText(prop)

	p.PrintPropText(prop.Okay, text)
}

func (p *propPrint) GetPropText(prop AddonStatusProp) string {
	switch {
	case prop.Okay == nil && prop.Message == nil:
		value := p.terminalPrinter.PrintCyanFg(fmt.Sprint(prop.Value))
		return fmt.Sprintf("%s: %s", prop.Name, value)
	case prop.Okay == nil && prop.Message != nil:
		return p.terminalPrinter.PrintCyanFg(*prop.Message)
	case prop.Okay != nil && prop.Message == nil:
		return fmt.Sprintf("%s: %v", prop.Name, prop.Value)
	default:
		return *prop.Message
	}
}

func (p *propPrint) PrintPropText(okay *bool, text string) {
	switch {
	case okay == nil:
		p.terminalPrinter.Println(text)
	case *okay:
		p.terminalPrinter.PrintSuccess(text)
	default:
		p.terminalPrinter.PrintWarning(text)
	}
}
