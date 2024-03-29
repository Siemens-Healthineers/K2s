// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package utils

import (
	"fmt"
	"log/slog"
	"runtime"
	"strings"

	gopshost "github.com/shirou/gopsutil/v3/host"
	"github.com/siemens-healthineers/k2s/internal/host"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

var installDir string

func init() {
	var err error
	installDir, err = host.ExecutableDir()
	if err != nil {
		panic(err)
	}
}

func InstallDir() string {
	return installDir
}

// platform generates a user-readable platform message
func Platform() string {
	var s strings.Builder
	// Show the distro version if possible
	hi, err := gopshost.Info()
	if err == nil {
		s.WriteString(fmt.Sprintf("%s %s", cases.Title(language.Und).String(hi.Platform), hi.PlatformVersion))
		slog.Debug("Host info", "info", hi)
	} else {
		slog.Warn("gopshost.Info returned error", "error", err)
		s.WriteString(runtime.GOOS)
	}

	return s.String()
}

func FormatScriptFilePath(filePath string) string {
	return "&'" + filePath + "'"
}

func EscapeWithDoubleQuotes(str string) string {
	return "\"" + str + "\""
}

func EscapeWithSingleQuotes(str string) string {
	return "'" + str + "'"
}
