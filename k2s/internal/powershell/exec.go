// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/go-cmd/cmd"
	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/logging"
	"github.com/siemens-healthineers/k2s/internal/powershell/decode"
)

type PowerShellCmdName string

type message []byte

type Decoder interface {
	IsEncodedMessage(message string) bool
	DecodeMessage(message string, targetType string) ([]byte, error)
}

type OutputWriter interface {
	WriteStd(line string)
	WriteErr(line string)
	Flush()
}

type messageDecoder struct{}

type executor struct {
	decoder Decoder
	writer  OutputWriter
}

const (
	Ps5CmdName PowerShellCmdName = "powershell"
	Ps7CmdName PowerShellCmdName = "pwsh"
)

func (messageDecoder) IsEncodedMessage(message string) bool {
	return decode.IsEncodedMessage(message)
}

func (messageDecoder) DecodeMessage(message string, targetType string) ([]byte, error) {
	return decode.DecodeMessage(message, targetType)
}

// ExecutePsWithStructuredResult waits until the command has finished and returns the structured data it received or errors that occurred
// Calls to OutputWriter happen asynchroniously
func ExecutePsWithStructuredResult[T any](psScriptPath string, targetType string, psVersion PowerShellVersion, writer OutputWriter, additionalParams ...string) (v T, err error) {
	if psVersion == "" {
		return v, errors.New("PowerShell version not specified")
	}

	cmdString := buildCmdString(psScriptPath, targetType, additionalParams...)
	cmdString, err = prepareExecScript(cmdString)
	if err != nil {
		return v, err
	}

	slog.Debug("PS command created", "command", cmdString)

	cmd, err := buildCmd(psVersion, cmdString)
	if err != nil {
		return v, err
	}

	executor := executor{
		decoder: messageDecoder{},
		writer:  writer,
	}

	messages, err := executor.execute(cmd, targetType)
	if err != nil {
		return v, err
	}

	return convertToResult[T](messages)
}

func (e *executor) execute(cmd *exec.Cmd, targetType string) ([]message, error) {
	stdOut, stdErr, err := setupCmdInOutStreams(cmd)
	if err != nil {
		return nil, err
	}

	messageChan := make(chan string)
	errorChan := make(chan string)

	go readStream(stdOut, messageChan)
	go readStream(stdErr, errorChan)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("command execution could not be started: %w", err)
	}

	slog.Debug("PS command started")

	messages := []message{}
	decodeErrors := []error{}

	for messageChan != nil || errorChan != nil {
		select {
		case errorLine, ok := <-errorChan:
			if !ok {
				errorChan = nil

				slog.Debug("Channel closed", "channel", "error")
				continue
			}
			e.writer.WriteErr(errorLine)
		case message, ok := <-messageChan:
			if !ok {
				messageChan = nil

				slog.Debug("Channel closed", "channel", "message")
				continue
			}
			if !e.decoder.IsEncodedMessage(message) {
				e.writer.WriteStd(message)
				continue
			}

			obj, err := e.decoder.DecodeMessage(message, targetType)
			if err != nil {
				decodeErrors = append(decodeErrors, err)
				continue
			}

			messages = append(messages, obj)

			slog.Debug("Message decoded")
		}
	}

	e.writer.Flush()

	slog.Debug("Waiting for PS command to finish")

	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("command execution failed, see log output above. Error: %w", err)
	}

	slog.Debug("PS command finished")

	return messages, errors.Join(decodeErrors...)
}

func buildCmdString(psScriptPath string, targetType string, additionalParams ...string) string {
	builder := strings.Builder{}
	builder.WriteString(psScriptPath + " -EncodeStructuredOutput -MessageType " + targetType)

	if len(additionalParams) > 0 {
		for _, param := range additionalParams {
			builder.WriteString(" " + param)
		}
	}
	return builder.String()
}

func buildCmd(psVersion PowerShellVersion, cmdString string) (*exec.Cmd, error) {
	if psVersion == PowerShellV7 {
		slog.Info("Switching to PowerShell 7 command syntax")

		if err := AssertPowerShellV7Installed(); err != nil {
			return nil, err
		}

		return exec.Command(string(Ps7CmdName), "-Command", cmdString), nil
	}

	slog.Info("Using PowerShell 5 command syntax")

	return exec.Command(string(Ps5CmdName), cmdString), nil
}

func setupCmdInOutStreams(cmd *exec.Cmd) (stdOut io.ReadCloser, stdErr io.ReadCloser, err error) {
	stdOut, err = cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}

	stdErr, err = cmd.StderrPipe()
	if err != nil {
		return nil, nil, err
	}

	cmd.Stdin = os.Stdin

	return
}

func readStream(stream io.ReadCloser, dataReceived chan string) {
	defer close(dataReceived)

	slog.Debug("routine started", "routine", "readStream")

	scanner := bufio.NewScanner(stream)

	for scanner.Scan() {
		dataReceived <- scanner.Text()
	}

	slog.Debug("routine finished", "routine", "readStream")
}

func convertToResult[T any](messages []message) (v T, err error) {
	if len(messages) != 1 {
		return v, fmt.Errorf("unexpected number of messages. Expected 1, but got %d", len(messages))
	}

	message := messages[0]

	if slog.Default().Enabled(context.Background(), slog.LevelDebug) {
		slog.Debug("Unmarshalling message", "message", string(message))
	}

	err = json.Unmarshal(message, &v)
	if err != nil {
		return v, fmt.Errorf("could not unmarshal message: %w", err)
	}

	slog.Info("Message unmarshalled")

	return
}

func ExecutePs(script string, psVersion PowerShellVersion) (time.Duration, error) {
	if psVersion == "" {
		return 0, errors.New("PowerShell version not specified")
	}

	psCmd := Ps5CmdName
	cmdArg := ""
	if psVersion == PowerShellV7 {
		psCmd = Ps7CmdName
		cmdArg = "-Command"

		slog.Info("Switching to PowerShell 7 command syntax")

		if err := AssertPowerShellV7Installed(); err != nil {
			return 0, err
		}
	}

	cmdOptions := cmd.Options{
		Buffered:   false,
		Streaming:  true,
		BeforeExec: []func(cmd *exec.Cmd){setStdin},
	}

	wrapperScript, err := prepareExecScript(script)
	cmdRun := cmd.NewCmdOptions(cmdOptions, string(psCmd), cmdArg, wrapperScript)
	doneChan := make(chan struct{})
	errorLineBuffer, err := logging.NewLogBuffer(logging.BufferConfig{
		Limit: 100,
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
	if err != nil {
		return 0, err
	}

	go readStdChannels(cmdRun, doneChan, errorLineBuffer.Log)

	statusChan := cmdRun.Start()
	finalStatus := <-statusChan
	<-doneChan

	errorLineBuffer.Flush()

	if finalStatus.Exit != 0 {
		return 0, fmt.Errorf("command execution failed, see log output above. Error: exit code %d", finalStatus.Exit)
	}

	seconds := math.Round(finalStatus.Runtime)
	duration := time.Second * time.Duration(int(seconds))

	return duration, nil
}

// TODO: merge/consolidate with k2s\internal\powershell\exec.go
func readStdChannels(cmdRun *cmd.Cmd, doneChan chan struct{}, logErrFunc func(line string)) {
	defer close(doneChan)

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
				pterm.Printfln("⏳ %s", line)
			}
		case line, open := <-cmdRun.Stderr:
			if !open {
				cmdRun.Stderr = nil
				continue
			}
			if len(line) > 0 {
				logErrFunc(line)
				pterm.Printfln("⏳ %s", pterm.Yellow(line))
			}
		}
	}
}

func setStdin(cmd *exec.Cmd) {
	cmd.Stdin = os.Stdin
}

func prepareExecScript(script string) (string, error) {
	slog.Debug("Execution script", "script", script)
	wrapperScript := ""

	installDir, err := host.ExecutableDir()
	if err != nil {
		return "", err
	}

	wrapperScript = ("&'" + installDir + "\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
	wrapperScript += "\"" + script + "\""

	slog.Debug("Final execution script", "script", wrapperScript)

	return wrapperScript, nil
}
