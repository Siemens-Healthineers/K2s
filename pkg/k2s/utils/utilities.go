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
	installationDirectory = determineInstallationDirectory()
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

func determineInstallationDirectory() string {
	_, currentFilePath, _, ok := runtime.Caller(0)
	if !ok {
		panic("source file path could not be determined")
	}

	currentDir := filepath.Dir(currentFilePath)

	// Look for VERSION file to find the Root dir
	versionFileName := "VERSION"
	for {
		versionFilePath := filepath.Join(currentDir, versionFileName)
		if _, err := os.Stat(versionFilePath); err == nil {
			return currentDir
		}

		// Move up one directory
		parentDir := filepath.Dir(currentDir)
		if parentDir == currentDir {
			// Reached the root without finding VERSION file
			panic("VERSION file not found")
		}

		currentDir = parentDir
	}
}
