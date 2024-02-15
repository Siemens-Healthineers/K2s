// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package utils

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	gopshost "github.com/shirou/gopsutil/v3/host"

	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"k8s.io/klog/v2"
)

// platform generates a user-readable platform message
func Platform() string {
	var s strings.Builder
	// Show the distro version if possible
	hi, err := gopshost.Info()
	if err == nil {
		s.WriteString(fmt.Sprintf("%s %s", cases.Title(language.Und).String(hi.Platform), hi.PlatformVersion))
		klog.V(4).Infof("hostinfo: %+v", hi)
	} else {
		klog.Warningf("gopshost.Info returned error: %v", err)
		s.WriteString(runtime.GOOS)
	}

	return s.String()
}

func init() {
	k2sExe, err := os.Executable()
	if err != nil {
		panic(err)
	}
	installationDirectory = filepath.Dir(k2sExe)
}

var installationDirectory string

func GetInstallationDirectory() string {
	return installationDirectory
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
