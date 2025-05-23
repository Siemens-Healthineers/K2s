// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
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
	PsCmd = "powershell"
)

func (messageDecoder) IsEncodedMessage(message string) bool {
	return decode.IsEncodedMessage(message)
}

func (messageDecoder) DecodeMessage(message string, targetType string) ([]byte, error) {
	return decode.DecodeMessage(message, targetType)
}

// ExecutePsWithStructuredResult waits until the command has finished and returns the structured data it received or errors that occurred
// Calls to OutputWriter happen asynchronous
func ExecutePsWithStructuredResult[T any](psScriptPath string, targetType string, writer os.StdWriter, additionalParams ...string) (v T, err error) {
	cmdString := buildCmdString(psScriptPath, targetType, additionalParams...)
	cmdString, err = prepareExecScript(cmdString)
	if err != nil {
		return v, err
	}

	slog.Debug("PS command created", "command", cmdString)

	structuredWriter := &structuredOutputWriter{
		decoder:      messageDecoder{},
		stdWriter:    writer,
		targetType:   targetType,
		messages:     []message{},
		decodeErrors: []error{},
	}
	exe := os.NewCmdExecutor(structuredWriter)

	err = exe.ExecuteCmd(PsCmd, cmdString)
	if err != nil {
		return v, err
	}

	err = errors.Join(structuredWriter.decodeErrors...)
	if err != nil {
		return v, err
	}

	return convertToResult[T](structuredWriter.messages)
}

func ExecutePs(script string, writer os.StdWriter) error {
	script, err := prepareExecScript(script)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", script)

	return os.NewCmdExecutor(writer).ExecuteCmd(PsCmd, script)
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

	slog.Debug("Message unmarshalled")

	return
}

func prepareExecScript(script string) (string, error) {
	slog.Debug("Execution script", "script", script)
	wrapperScript := ""

	installDir, err := os.ExecutableDir()
	if err != nil {
		return "", err
	}

	// check if there is an directory lib folder
	if os.PathExists(installDir + "\\lib") {
		wrapperScript = ("&'" + installDir + "\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
		wrapperScript += "\"" + script + "\""
	} else {
		// we assume we have a binary under bin path and not in the root
		wrapperScript = ("&'" + installDir + "\\..\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
		wrapperScript += "\"" + script + "\""
	}

	slog.Debug("Final execution script", "script", wrapperScript)

	return wrapperScript, nil
}
