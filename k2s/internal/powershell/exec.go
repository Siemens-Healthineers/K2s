// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell/decode"
)

type PowerShellCmdName string

type message []byte

type Decoder interface {
	IsEncodedMessage(message string) bool
	DecodeMessage(message string, targetType string) ([]byte, error)
}

type messageDecoder struct{}

type structuredOutputWriter struct {
	decoder      Decoder
	stdWriter    os.StdWriter
	targetType   string
	messages     []message
	decodeErrors []error
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
// Calls to OutputWriter happen asynchronous
func ExecutePsWithStructuredResult[T any](psScriptPath string, targetType string, psVersion PowerShellVersion, writer os.StdWriter, additionalParams ...string) (v T, err error) {
	if psVersion == "" {
		return v, errors.New("PowerShell version not specified")
	}

	cmdString := buildCmdString(psScriptPath, targetType, additionalParams...)
	cmdString, err = prepareExecScript(cmdString)
	if err != nil {
		return v, err
	}

	slog.Debug("PS command created", "command", cmdString)

	cmdName, args, err := buildCmd(psVersion, cmdString)
	if err != nil {
		return v, err
	}

	structuredWriter := &structuredOutputWriter{
		decoder:      messageDecoder{},
		stdWriter:    writer,
		targetType:   targetType,
		messages:     []message{},
		decodeErrors: []error{},
	}
	exe := os.NewCmdExecutor(structuredWriter)

	err = exe.ExecuteCmd(cmdName, args...)
	if err != nil {
		return v, err
	}

	err = errors.Join(structuredWriter.decodeErrors...)
	if err != nil {
		return v, err
	}

	return convertToResult[T](structuredWriter.messages)
}

func ExecutePs(script string, psVersion PowerShellVersion, writer os.StdWriter) error {
	if psVersion == "" {
		return errors.New("PowerShell version not specified")
	}

	script, err := prepareExecScript(script)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", script)

	cmdName, args, err := buildCmd(psVersion, script)
	if err != nil {
		return err
	}

	return os.NewCmdExecutor(writer).ExecuteCmd(cmdName, args...)
}

func (sWriter *structuredOutputWriter) WriteStdOut(message string) {
	if !sWriter.decoder.IsEncodedMessage(message) {
		sWriter.stdWriter.WriteStdOut(message)
		return
	}

	obj, err := sWriter.decoder.DecodeMessage(message, sWriter.targetType)
	if err != nil {
		sWriter.decodeErrors = append(sWriter.decodeErrors, err)
		return
	}

	sWriter.messages = append(sWriter.messages, obj)

	slog.Debug("Message decoded")
}

func (sWriter *structuredOutputWriter) WriteStdErr(message string) {
	sWriter.stdWriter.WriteStdErr(message)
}

func (sWriter *structuredOutputWriter) Flush() {
	sWriter.stdWriter.Flush()
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

func buildCmd(psVersion PowerShellVersion, cmdString string) (string, []string, error) {
	if psVersion == PowerShellV7 {
		slog.Info("Switching to PowerShell 7 command syntax")

		if err := AssertPowerShellV7Installed(); err != nil {
			return "", nil, err
		}

		return string(Ps7CmdName), []string{"-Command", cmdString}, nil
	}

	slog.Info("Using PowerShell 5 command syntax")

	return string(Ps5CmdName), []string{cmdString}, nil
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

	installDir, err := os.ExecutableDir()
	if err != nil {
		return "", err
	}

	wrapperScript = ("&'" + installDir + "\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
	wrapperScript += "\"" + script + "\""

	slog.Debug("Final execution script", "script", wrapperScript)

	return wrapperScript, nil
}
