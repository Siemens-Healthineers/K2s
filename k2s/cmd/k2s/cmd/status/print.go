// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/primitives/arrays"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type TerminalPrinter interface {
	Println(m ...any)
	PrintCyanFg(text string) string
	PrintRedFg(text string) string
	PrintGreenFg(text string) string
	PrintHeader(m ...any)
	StartSpinner(m ...any) (any, error)
	PrintSuccess(m ...any)
	PrintInfoln(m ...any)
	PrintWarning(m ...any)
	PrintTreeListItems(items []string)
	PrintTableWithHeaders(table [][]string)
}

type Spinner interface {
	Stop() error
}

type JsonPrinter struct {
	basePrinter
	printlnFunc       func(m ...any)
	marshalIndentFunc func(data any) ([]byte, error)
}

type UserFriendlyPrinter struct {
	basePrinter
	showAdditionalInfo bool
	terminalPrinter    TerminalPrinter
}

type PrintStatus struct {
	SetupInfo      *PrintSetupInfo `json:"setupInfo"`
	RunningState   *RunningState   `json:"runningState"`
	Nodes          []Node          `json:"nodes"`
	Pods           []Pod           `json:"pods"`
	K8sVersionInfo *K8sVersionInfo `json:"k8sVersionInfo"`
	Error          *string         `json:"error"`
}

type PrintSetupInfo struct {
	Version   string `json:"version"`
	Name      string `json:"name"`
	LinuxOnly bool   `json:"linuxOnly"`
}

type basePrinter struct {
	config   *setupinfo.Config
	loadFunc func() (*LoadedStatus, error)
}

func NewJsonPrinter(
	config *setupinfo.Config,
	printlnFunc func(m ...any),
	marshalIndentFunc func(data any) ([]byte, error),
	loadFunc func() (*LoadedStatus, error)) *JsonPrinter {
	return &JsonPrinter{
		basePrinter: basePrinter{
			config:   config,
			loadFunc: loadFunc},
		printlnFunc:       printlnFunc,
		marshalIndentFunc: marshalIndentFunc,
	}
}

func NewUserFriendlyPrinter(
	config *setupinfo.Config,
	showAdditionalInfo bool,
	terminalPrinter TerminalPrinter,
	loadFunc func() (*LoadedStatus, error)) *UserFriendlyPrinter {
	return &UserFriendlyPrinter{
		basePrinter: basePrinter{
			config:   config,
			loadFunc: loadFunc},
		showAdditionalInfo: showAdditionalInfo,
		terminalPrinter:    terminalPrinter,
	}
}

func (p *JsonPrinter) Print() error {
	loadedStatus, err := p.loadFunc()
	if err != nil {
		return err
	}

	printStatus := PrintStatus{
		SetupInfo: &PrintSetupInfo{
			Version:   p.config.Version,
			Name:      string(p.config.SetupName),
			LinuxOnly: p.config.LinuxOnly,
		},
		RunningState:   loadedStatus.RunningState,
		Nodes:          loadedStatus.Nodes,
		Pods:           loadedStatus.Pods,
		K8sVersionInfo: loadedStatus.K8sVersionInfo,
	}

	var deferredErr error
	if loadedStatus.Failure != nil {
		printStatus.Error = &loadedStatus.Failure.Code
		loadedStatus.Failure.SuppressCliOutput = true
		deferredErr = loadedStatus.Failure
	}

	slog.Info("Marhalling", "status", printStatus)

	bytes, err := p.marshalIndentFunc(printStatus)
	if err != nil {
		return err
	}

	statusJson := string(bytes)

	slog.Info("Printing", "json", statusJson)

	p.printlnFunc(statusJson)

	return deferredErr
}

func (p *UserFriendlyPrinter) Print() error {
	spinner, err := common.StartSpinner(p.terminalPrinter)
	if err != nil {
		return err
	}

	status, err := p.loadFunc()

	common.StopSpinner(spinner)

	if err != nil {
		return fmt.Errorf("status could not be loaded: %w", err)
	}

	if status.Failure != nil {
		return status.Failure
	}

	if status.RunningState == nil {
		return errors.New("no running state info retrieved")
	}

	p.terminalPrinter.PrintHeader("K2s SYSTEM STATUS")

	typeText := string(p.config.SetupName)
	if p.config.LinuxOnly {
		typeText += " (Linux-only)"
	}

	printText := fmt.Sprintf("Setup: '%s', Version: '%s'", p.terminalPrinter.PrintCyanFg(typeText), p.terminalPrinter.PrintCyanFg(p.config.Version))

	p.terminalPrinter.Println(printText)

	if !status.RunningState.IsRunning {
		p.terminalPrinter.PrintInfoln("The system is not running. Run 'k2s start' to start the system")
		p.terminalPrinter.PrintTreeListItems(status.RunningState.Issues)
		return nil
	}

	p.terminalPrinter.PrintSuccess("The system is running")

	if p.config.SetupName == setupinfo.SetupNameBuildOnlyEnv {
		slog.Debug("Setup type has no K8s components, skipping", "type", setupinfo.SetupNameBuildOnlyEnv)
		return nil
	}

	p.terminalPrinter.Println()

	if status.K8sVersionInfo == nil {
		return errors.New("no K8s version info retrieved")
	}

	p.printK8sVersion(status.K8sVersionInfo.K8sServerVersion, "server")
	p.printK8sVersion(status.K8sVersionInfo.K8sClientVersion, "client")

	proceed := p.printNodesStatus(status.Nodes, p.showAdditionalInfo)
	if !proceed {
		return nil
	}

	p.printPodsStatus(status.Pods, p.showAdditionalInfo)

	return nil
}

func (p *UserFriendlyPrinter) printK8sVersion(version string, versionType string) {
	versionText := p.terminalPrinter.PrintCyanFg(version)
	line := fmt.Sprintf("K8s %s version: '%s'", versionType, versionText)

	p.terminalPrinter.Println(line)
}

func (p *UserFriendlyPrinter) printNodesStatus(nodes []Node, showAdditionalInfo bool) bool {
	if len(nodes) == 0 {
		return false
	}

	headers := createNodeHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allOkay := p.buildNodeRows(nodes, showAdditionalInfo)

	table = append(table, rows...)

	p.terminalPrinter.PrintTableWithHeaders(table)

	if allOkay {
		p.terminalPrinter.PrintSuccess("All nodes are ready")
	} else {
		p.terminalPrinter.PrintWarning("Some nodes are not ready")
	}

	p.terminalPrinter.Println()

	return allOkay
}

func (p *UserFriendlyPrinter) printPodsStatus(pods []Pod, showAdditionalInfo bool) {
	if len(pods) == 0 {
		return
	}

	headers := createPodHeaders(showAdditionalInfo)

	table := [][]string{headers}

	rows, allOkay := p.buildPodRows(pods, showAdditionalInfo)

	table = append(table, rows...)

	p.terminalPrinter.PrintTableWithHeaders(table)

	if allOkay {
		p.terminalPrinter.PrintSuccess("All essential Pods are running")
	} else {
		p.terminalPrinter.PrintWarning("Some essential Pods are not running")
	}

	p.terminalPrinter.Println()
}

func createNodeHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "ROLE", "AGE", "VERSION"}

	if showAdditionalInfo {
		headers = append(headers, "INTERNAL-IP", "OS-IMAGE", "KERNEL-VERSION", "CONTAINER-RUNTIME")
	}

	return headers
}

func createPodHeaders(showAdditionalInfo bool) []string {
	headers := []string{"STATUS", "NAME", "READY", "RESTARTS", "AGE"}

	if showAdditionalInfo {
		headers = arrays.Insert(headers, "NAMESPACE", 1)
		headers = append(headers, "IP", "NODE")
	}

	return headers
}

func (p *UserFriendlyPrinter) buildNodeRows(nodes []Node, showAdditionalInfo bool) ([][]string, bool) {
	allOkay := true
	var rows [][]string

	for _, node := range nodes {
		row := p.buildNodeRow(node, showAdditionalInfo)
		if !node.IsReady {
			allOkay = false
		}

		rows = append(rows, row)
	}

	return rows, allOkay
}

func (p *UserFriendlyPrinter) buildPodRows(pods []Pod, showAdditionalInfo bool) ([][]string, bool) {
	allOkay := true
	var rows [][]string

	for _, pod := range pods {
		row := p.buildPodRow(pod, showAdditionalInfo)
		if !pod.IsRunning {
			allOkay = false
		}

		rows = append(rows, row)
	}

	return rows, allOkay
}

func (p *UserFriendlyPrinter) buildNodeRow(node Node, showAdditionalInfo bool) []string {
	status := p.determineStatusColor(node.IsReady, node.Status)

	row := []string{status, node.Name, node.Role, node.Age, node.KubeletVersion}

	if showAdditionalInfo {
		row = append(row, node.InternalIp, node.OsImage, node.KernelVersion, node.ContainerRuntime)
	}

	return row
}

func (p *UserFriendlyPrinter) buildPodRow(pod Pod, showAdditionalInfo bool) []string {
	status := p.determineStatusColor(pod.IsRunning, pod.Status)

	row := []string{status, pod.Name, pod.Ready, pod.Restarts, pod.Age}

	if showAdditionalInfo {
		row = arrays.Insert(row, pod.Namespace, 1)
		row = append(row, pod.Ip, pod.Node)
	}

	return row
}

func (p *UserFriendlyPrinter) determineStatusColor(isOkay bool, status string) string {
	if isOkay {
		return p.terminalPrinter.PrintGreenFg(status)
	}
	return p.terminalPrinter.PrintRedFg(status)
}
