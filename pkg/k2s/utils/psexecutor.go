// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package utils

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"k2s/config"
	"k2s/setupinfo"
	"math"
	"os"
	"os/exec"
	"strings"
	"time"

	"k2s/providers/marshalling"

	"github.com/go-cmd/cmd"
	"github.com/pterm/pterm"
	"k8s.io/klog/v2"
)

type cliMessage struct {
	MsgData []byte
	MsgType string
}

type ExecOptions struct {
	NoProgress            bool
	IgnoreNotInstalledErr bool
	PowerShellVersion     PowerShellVersion
}

type PowerShellVersion string

const (
	marker = "#pm#"

	PowerShellV5 PowerShellVersion = "5"
	PowerShellV7 PowerShellVersion = "7"
	ps5CmdName                     = "powershell"
	ps7CmdName                     = "pwsh"
)

func ExecutePowershellScript(script string, options ...ExecOptions) (time.Duration, error) {
	execOptions, err := determineExecOptions(options...)
	if err != nil {
		return 0, err
	}

	return executePowershellScript(script, *execOptions)
}

func ExecutePsWithStructuredResult[T any](psScriptPath string, resultTypeName string, options ExecOptions, additionalParams ...string) (v T, err error) {
	cmd := psScriptPath + " -EncodeStructuredOutput -MessageType " + resultTypeName
	if len(additionalParams) > 0 {
		for _, param := range additionalParams {
			cmd += " " + param
		}
	}

	klog.V(4).Infoln("PS command created:", cmd)

	dataObjects, err := executePowershellScriptWithDataSubscription(cmd, options)
	if err != nil {
		return v, err
	}

	if len(dataObjects) != 1 {
		return v, fmt.Errorf("unexpected number of data objects. Expected 1, but got %d", len(dataObjects))
	}

	dataObj := dataObjects[0]

	if dataObj.Type() != resultTypeName {
		return v, fmt.Errorf("unexpected result type. Expected '%s', but got '%s'", resultTypeName, dataObj.Type())
	}

	klog.V(4).Infoln("unmarshalling data object..")

	marshaller := marshalling.NewJsonUnmarshaller()

	err = marshaller.Unmarshal(dataObj.Data(), &v)
	if err != nil {
		return v, fmt.Errorf("could not unmarshal structure: %s", err)
	}

	klog.V(4).Infoln("data object unmarshalled")

	return v, nil
}

func (m cliMessage) Data() []byte {
	return m.MsgData
}

func (m cliMessage) Type() string {
	return m.MsgType
}

// executePowershellScriptWithDataSubscription waits until the command has finished and returns the structured data it received
func executePowershellScriptWithDataSubscription(cmdString string, options ...ExecOptions) ([]interface {
	Data() []byte
	Type() string
}, error) {
	execOptions, err := determineExecOptions(options...)
	if err != nil {
		return nil, err
	}

	cmd, err := createCmd(execOptions.PowerShellVersion, cmdString)
	if err != nil {
		return nil, err
	}

	stdOutReader, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}

	stdErrReader, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}

	dataObjects := []interface {
		Data() []byte
		Type() string
	}{}
	errorLogs := []string{}
	errors := []error{}

	logChan := make(chan string)
	errLogChan := make(chan string)
	dataObjChan := make(chan cliMessage)
	errChan := make(chan error)

	go readStdOut(stdOutReader, logChan, dataObjChan, errChan)
	go readStdErr(stdErrReader, errLogChan)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("command execution could not be started: %s", err)
	}

	klog.V(8).Info("PS command started")

	for logChan != nil || errLogChan != nil || dataObjChan != nil || errChan != nil {
		select {
		case log, ok := <-logChan:
			if !ok {
				logChan = nil

				klog.V(8).Info("channel closed: log")
				continue
			}
			pterm.Printfln("⏳ %s", log)
		case errorLog, ok := <-errLogChan:
			if !ok {
				errLogChan = nil

				klog.V(8).Info("channel closed: err log")
				continue
			}
			errorLogs = append(errorLogs, errorLog)
			pterm.Printfln("⏳ %s", pterm.Yellow(errorLog))
		case dataObj, ok := <-dataObjChan:
			if !ok {
				dataObjChan = nil

				klog.V(8).Info("channel closed: data obj")
				continue
			}
			dataObjects = append(dataObjects, dataObj)

			klog.V(8).Info("data obj received")
		case err, ok := <-errChan:
			if !ok {
				errChan = nil

				klog.V(8).Info("channel closed: err")
				continue
			}
			errors = append(errors, err)

			klog.V(8).Info("error received")
		}
	}

	if len(errorLogs) > 0 {
		klog.Error(strings.Join(errorLogs, "\n"))
	}

	klog.V(8).Info("waiting for PS command to finish..")

	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("command execution failed, see log output above. Error: %s", err)
	}

	klog.V(8).Info("PS command finished")

	if len(errors) > 0 {
		errorsText := ""
		for _, err := range errors {
			errorsText += err.Error() + "\n"
		}

		return nil, fmt.Errorf("errors occurred during execution:\n%s", errorsText)
	}

	return dataObjects, nil
}

func determineExecOptions(options ...ExecOptions) (*ExecOptions, error) {
	var execOptions *ExecOptions
	if len(options) > 0 {
		klog.V(8).Infof("found '%d' exec options, taking first one", len(options))

		execOptions = &options[0]
	} else {
		klog.V(8).Infoln("did not find any exec options, resuming with default options")

		execOptions = &ExecOptions{}
	}

	if execOptions.PowerShellVersion == "" {
		klog.V(8).Infoln("no PowerShell version option found, determining..")

		psVersion, err := determinePsVersion(execOptions.IgnoreNotInstalledErr)
		if err != nil {
			return nil, err
		}

		execOptions.PowerShellVersion = psVersion

		klog.V(8).Infof("PowerShell version %s determined", psVersion)
	}

	return execOptions, nil
}

func createCmd(psVersion PowerShellVersion, cmdString string) (*exec.Cmd, error) {
	if psVersion == PowerShellV7 {
		klog.V(4).Info("Switching to PowerShell 7 command syntax")

		if err := checkIfCommandExists(ps7CmdName); err != nil {
			return nil, err
		}

		return exec.Command(ps7CmdName, "-Command", cmdString), nil
	}

	klog.V(4).Info("Using PowerShell 5 command syntax")

	return exec.Command(ps5CmdName, cmdString), nil
}

func readStdErr(reader io.ReadCloser, logReceived chan string) {
	defer close(logReceived)

	klog.V(8).Info("routine started: readStdErr")

	scanner := bufio.NewScanner(reader)

	for scanner.Scan() {
		message := scanner.Text()

		logReceived <- message
	}

	klog.V(8).Info("routine finished: readStdErr")
}

func readStdOut(reader io.ReadCloser, logReceived chan string, messageReceived chan cliMessage, errOccurred chan error) {
	defer close(logReceived)
	defer close(messageReceived)
	defer close(errOccurred)

	klog.V(8).Info("routine started: readStdOut")

	stdScanner := bufio.NewScanner(reader)

	for stdScanner.Scan() {
		message := stdScanner.Text()

		if !strings.HasPrefix(message, marker) {
			logReceived <- message
			continue
		}

		msgParts := strings.Split(message, "#")

		if len(msgParts) != 4 {
			errorMessage := fmt.Sprintf("message malformed, fount %d parts", len(msgParts))
			errOccurred <- errors.New(errorMessage)
			return
		}

		msgBytes := []byte(msgParts[3])

		decodedBytes := make([]byte, base64.StdEncoding.DecodedLen(len(msgBytes)))
		decodedLen, err := base64.StdEncoding.Decode(decodedBytes, msgBytes)
		if err != nil {
			errOccurred <- err
			return
		}

		reader, err := gzip.NewReader(bytes.NewReader(decodedBytes[:decodedLen]))
		if err != nil {
			errOccurred <- err
			return
		}

		uncompressedBytes, err := io.ReadAll(reader)
		if err != nil {
			errOccurred <- err
			return
		}

		cliMsg := cliMessage{
			MsgData: uncompressedBytes,
			MsgType: msgParts[2],
		}

		messageReceived <- cliMsg
	}

	klog.V(8).Info("routine finished: readStdOut")
}

func executePowershellScript(script string, options ExecOptions) (time.Duration, error) {
	psCmd := ps5CmdName
	cmdArg := ""
	if options.PowerShellVersion == PowerShellV7 {
		psCmd = ps7CmdName
		cmdArg = "-Command"

		klog.V(4).Info("Switching to PowerShell 7 command syntax")

		if err := checkIfCommandExists(ps7CmdName); err != nil {
			return 0, err
		}
	}

	cmdOptions := cmd.Options{
		Buffered:   false,
		Streaming:  true,
		BeforeExec: []func(cmd *exec.Cmd){setStdin},
	}

	wrapperScript := prepareExecScript(script, options.NoProgress)
	cmdRun := cmd.NewCmdOptions(cmdOptions, psCmd, cmdArg, wrapperScript)
	doneChan := make(chan struct{})

	go readStdChannels(cmdRun, doneChan, options.NoProgress)

	statusChan := cmdRun.Start()
	finalStatus := <-statusChan
	<-doneChan

	if finalStatus.Exit != 0 {
		return 0, fmt.Errorf("command execution failed, see log output above. Error: exit code %d", finalStatus.Exit)
	}

	seconds := math.Round(finalStatus.Runtime)
	duration := time.Second * time.Duration(int(seconds))

	return duration, nil
}

// TODO: decision should not be made in utils package
func determinePsVersion(ignoreNotInstalledErr bool) (PowerShellVersion, error) {
	configAccess := config.NewAccess()
	setupName, err := configAccess.GetSetupName()
	if err != nil {
		if err == setupinfo.ErrNotInstalled && ignoreNotInstalledErr {
			klog.V(2).ErrorS(err, "setup not installed, falling back to default PowerShell version", "PowerShell", PowerShellV5)

			return PowerShellV5, nil
		}

		return "", err
	}

	linuxOnly, err := configAccess.IsLinuxOnly()
	if err != nil {
		return "", err
	}

	if setupName == setupinfo.SetupNameMultiVMK8s && !linuxOnly {
		return PowerShellV7, nil
	}

	return PowerShellV5, nil
}

// TODO: merge/consolidate stdout/stderr-reader functions
func readStdChannels(cmdRun *cmd.Cmd, doneChan chan struct{}, noProgress bool) {
	defer close(doneChan)

	errorLogs := []string{}

	// Done when both channels have been closed
	// https://dave.cheney.net/2013/04/30/curious-channels
	for cmdRun.Stdout != nil || cmdRun.Stderr != nil {
		select {
		case line, open := <-cmdRun.Stdout:
			if !open {
				cmdRun.Stdout = nil
				continue
			}
			if len(line) > 0 {
				if noProgress {
					pterm.Println(line)
				} else {
					pterm.Printfln("⏳ %s", line)
				}

			}
		case line, open := <-cmdRun.Stderr:
			if !open {
				cmdRun.Stderr = nil
				continue
			}
			if len(line) > 0 {
				errorLogs = append(errorLogs, line)
				pterm.Printfln("⏳ %s", pterm.Yellow(line))
			}
		}
	}

	if len(errorLogs) > 0 {
		klog.Error(strings.Join(errorLogs, "\n"))
	}
}

func setStdin(cmd *exec.Cmd) {
	cmd.Stdin = os.Stdin
}

func checkIfCommandExists(cmd string) error {
	_, err := exec.LookPath(cmd)
	if err == nil {
		klog.V(4).Info("PowerShell 7 is installed")
		return nil
	}

	// TODO: could be nicer :-)
	return fmt.Errorf("%s\nPlease install Powershell 7: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows", err)
}

func prepareExecScript(script string, noProgress bool) string {
	klog.V(4).Infof("Execution Script: %s", script)
	wrapperScript := ""

	if noProgress {
		wrapperScript = script
	} else {
		wrapperScript = ("&'" + GetInstallationDirectory() + "\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
		wrapperScript += EscapeWithDoubleQuotes(script)
	}

	klog.V(4).Infof("Final Execution Script: %s", wrapperScript)
	return wrapperScript
}
