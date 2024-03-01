// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"k2s/cmd/common"
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
	LoadAddonStatus(addonName string, addonDirectory string) (*LoadedAddonStatus, error)
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
	terminalPrinter           TerminalPrinter
	statusLoader              StatusLoader
	propPrinter               PropPrinter
	printAddonNotFoundMsgFunc func(dir string, name string)
	printNoAddonStatusMsgFunc func(name string)
}

type AddonPrintStatus struct {
	Name    string            `json:"name"`
	Enabled *bool             `json:"enabled"`
	Props   []AddonStatusProp `json:"props"`
	Error   *string           `json:"error"`
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

func NewUserFriendlyPrinter(
	terminalPrinter TerminalPrinter,
	statusLoader StatusLoader,
	propPrinters ...PropPrinter) *UserFriendlyPrinter {
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

func (s *JsonPrinter) PrintStatus(addonName string, addonDirectory string) error {
	klog.V(4).Infof("Loading status for addon '%s' in dir '%s'..", addonName, addonDirectory)

	loadedStatus, err := s.statusLoader.LoadAddonStatus(addonName, addonDirectory)

	var cmdFailure *common.CmdFailure
	printStatus := AddonPrintStatus{
		Name: addonName,
	}

	if err != nil {
		if !errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return err
		}

		cmdFailure = &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     setupinfo.ErrSystemNotInstalled.Error(),
			Message:  common.ErrSystemNotInstalledMsg,
		}
	} else {
		cmdFailure = loadedStatus.Failure
	}

	var deferredErr error
	if cmdFailure != nil {
		printStatus.Error = &cmdFailure.Code
		cmdFailure.SuppressCliOutput = true
		deferredErr = cmdFailure
	} else {
		printStatus.Enabled = loadedStatus.Enabled
		printStatus.Props = loadedStatus.Props
	}

	klog.V(4).Infof("Marhalling status: %v", printStatus)

	bytes, err := s.jsonMarshaller.MarshalIndent(printStatus)
	if err != nil {
		return err
	}

	statusJson := string(bytes)

	klog.V(4).Infof("Printing status JSON: %s", statusJson)

	s.terminalPrinter.Println(statusJson)

	return deferredErr
}

func (s *UserFriendlyPrinter) PrintStatus(addonName string, addonDirectory string) error {
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

	if status.Failure != nil {
		return status.Failure
	}

	if status.Enabled == nil {
		return fmt.Errorf("enabled/disabled info missing for '%s' addon", addonName)
	}

	s.terminalPrinter.PrintHeader("ADDON STATUS")

	coloredAddonName := s.terminalPrinter.PrintCyanFg(addonName)

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
