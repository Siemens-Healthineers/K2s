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
	"os"
	"os/exec"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/host"
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

func ExecutePs(script string, psVersion PowerShellVersion, writer OutputWriter) error {
	if psVersion == "" {
		return errors.New("PowerShell version not specified")
	}

	script, err := prepareExecScript(script)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", script)

	cmd, err := buildCmd(psVersion, script)
	if err != nil {
		return err
	}

	executor := executor{
		decoder: messageDecoder{},
		writer:  writer,
	}

	_, err = executor.execute(cmd, "")
	if err != nil {
		return err
	}

	return nil
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
