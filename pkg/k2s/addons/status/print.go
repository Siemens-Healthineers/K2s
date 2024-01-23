// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"k2s/setupinfo"

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
	terminalPrinter          TerminalPrinter
	statusLoader             StatusLoader
	propPrinter              PropPrinter
	printNotInstalledMsgFunc func()
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

func NewUserFriendlyPrinter(terminalPrinter TerminalPrinter, statusLoader StatusLoader, printNotInstalledMsgFunc func(), propPrinters ...PropPrinter) *UserFriendlyPrinter {
	var propPrinter PropPrinter
	if len(propPrinters) > 0 {
		propPrinter = propPrinters[0]
	} else {
		propPrinter = NewPropPrinter(terminalPrinter)
	}

	return &UserFriendlyPrinter{
		terminalPrinter:          terminalPrinter,
		statusLoader:             statusLoader,
		propPrinter:              propPrinter,
		printNotInstalledMsgFunc: printNotInstalledMsgFunc,
	}
}

func NewPropPrinter(terminalPrinter TerminalPrinter) *propPrint {
	return &propPrint{
		terminalPrinter: terminalPrinter,
	}
}

func (s *JsonPrinter) PrintStatus(addonName string, addonDirectory string) error {
	status, err := s.statusLoader.LoadAddonStatus(addonName, addonDirectory)
	if err != nil {
		return err
	}

	bytes, err := s.jsonMarshaller.MarshalIndent(status)
	if err != nil {
		return err
	}

	s.terminalPrinter.Println(string(bytes))

	return nil
}

func (s *UserFriendlyPrinter) PrintStatus(addonName string, addonDirectory string) error {
	s.terminalPrinter.PrintHeader("ADDON STATUS")

	startResult, err := s.terminalPrinter.StartSpinner("Gathering status information...")
	if err != nil {
		return err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return errors.New("could not start addon status operation")
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			klog.Error(err)
		}
	}()

	status, err := s.statusLoader.LoadAddonStatus(addonName, addonDirectory)
	if err != nil {
		return err
	}

	if status.Error != nil {
		if *status.Error == string(setupinfo.ErrNotInstalled) {
			s.printNotInstalledMsgFunc()
			return nil
		}

		s.terminalPrinter.Println(*status.Error)
		klog.V(2).Infof("addon status for '%s' returned error '%s'", addonName, *status.Error)
		return nil
	}

	if status.Enabled == nil {
		return fmt.Errorf("enabled/disabled info missing for '%s' addon", addonName)
	}

	coloredAddonName := s.terminalPrinter.PrintCyanFg(status.Name)

	if !*status.Enabled {
		s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("disabled"))
		return nil
	}

	s.terminalPrinter.Println("Addon", coloredAddonName, "is", s.terminalPrinter.PrintCyanFg("enabled"))

	for _, prop := range status.Props {
		s.propPrinter.PrintProp(prop)
	}

	return nil
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
