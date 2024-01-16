// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/klog/v2"
)

func Initialize(logFilePath string) {
	klog.InitFlags(nil)

	createLogDirIfNotExisting(filepath.Dir(logFilePath))

	setKlogFlag("logtostderr", "false")
	setKlogFlag("log_file", logFilePath)
	EnableCliOutput()
}

func SetVerbosity(level int) {
	setKlogFlag("v", fmt.Sprint(level))
}

func DisableCliOutput() {
	setKlogFlag("alsologtostderr", "false")
}

func EnableCliOutput() {
	setKlogFlag("alsologtostderr", "true")
}

func Finalize() {
	klog.Flush()
}

func Exit(args ...any) {
	klog.Exit(args...)
}

func createLogDirIfNotExisting(logDir string) {
	_, err := os.Stat(logDir)
	if !os.IsNotExist(err) {
		return
	}

	if err = os.MkdirAll(logDir, os.ModePerm); err != nil {
		panic(err)
	}
}

func setKlogFlag(name string, value string) {
	if err := flag.Set(name, value); err != nil {
		panic(err)
	}
}
