// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"fmt"
	"log"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/common"

	bl "github.com/siemens-healthineers/k2s/internal/logging"

	slogmulti "github.com/samber/slog-multi"
)

var (
	logFile    *os.File
	cliLogger  slog.Handler
	fileLogger slog.Handler
)

func Initialize() *slog.LevelVar {
	if logFile != nil {
		panic("logging already initialized")
	}

	logFilePath := filepath.Join(bl.RootLogDir(), "cli", fmt.Sprintf("%s.exe.log", common.CliName))
	logFile = bl.InitializeLogFile(logFilePath)

	var levelVar = new(slog.LevelVar)
	options := createDefaultOptions(levelVar)
	cliLogger = createCliLogger(options)
	fileLogger = createFileLogger(logFile, options)

	slog.SetDefault(slog.New(slogmulti.Fanout(cliLogger, fileLogger)))

	return levelVar
}

func Finalize() {
	if logFile == nil {
		return
	}

	if err := logFile.Sync(); err != nil {
		log.Fatal(err)
	}
	if err := logFile.Close(); err != nil {
		log.Fatal(err)
	}
}

func DisableCliOutput() {
	slog.SetDefault(slog.New(fileLogger))
}

func createDefaultOptions(levelVar *slog.LevelVar) *slog.HandlerOptions {
	return &slog.HandlerOptions{
		Level:       levelVar,
		AddSource:   true,
		ReplaceAttr: bl.ReplaceSourceFilePath}
}

func createCliLogger(options *slog.HandlerOptions) slog.Handler {
	return slog.NewTextHandler(os.Stdout, options)
}

func createFileLogger(file *os.File, options *slog.HandlerOptions) slog.Handler {
	return slog.NewJSONHandler(file, options)
}
