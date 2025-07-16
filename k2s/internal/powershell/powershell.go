// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package powershell

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell/decode"
)

type structuredOutputWriter struct {
	isEncodedMessage func(message string) bool
	stdWriter        os.StdWriter
	rawMessages      []string
}

const PsCmd = "powershell"

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
		isEncodedMessage: decode.IsEncodedMessage,
		stdWriter:        writer,
		rawMessages:      []string{},
	}
	exe := os.NewCmdExecutor(structuredWriter)

	err = exe.ExecuteCmd(PsCmd, cmdString)
	if err != nil {
		return v, err
	}

	decodedMessage, err := decode.DecodeMessages(structuredWriter.rawMessages, targetType)
	if err != nil {
		return v, err
	}

	return convertToResult[T](decodedMessage)
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
	if !sWriter.isEncodedMessage(message) {
		sWriter.stdWriter.WriteStdOut(message)
		return
	}

	sWriter.rawMessages = append(sWriter.rawMessages, message)

	slog.Debug("Raw message received")
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

func convertToResult[T any](message []byte) (v T, err error) {
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
