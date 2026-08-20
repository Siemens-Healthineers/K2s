// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package os

import (
	bos "os"
	"path/filepath"
	"runtime"
	"strings"
)

// ExecutableFileName returns the platform-specific executable file name for the
// given base name, e.g. "k2s" -> "k2s.exe" on Windows and "k2s" on Linux.
func ExecutableFileName(baseName string) string {
	if runtime.GOOS == "windows" {
		return baseName + ".exe"
	}
	return baseName
}

// FindExecutablesInPath scans the process' PATH environment variable and returns
// the absolute paths of all existing files named exeName.
//
// Non-existing PATH entries are silently skipped. The returned slice preserves
// PATH order.
func FindExecutablesInPath(exeName string) ([]string, error) {
	pathEnv := bos.Getenv("PATH")
	if pathEnv == "" {
		return nil, nil
	}
	var found []string
	for _, dir := range filepath.SplitList(pathEnv) {
		if dir == "" || dir == "." {
			continue
		}
		exePath := filepath.Join(dir, exeName)
		absExePath, err := filepath.Abs(exePath)
		if err != nil {
			continue
		}
		if info, err := bos.Stat(absExePath); err == nil && !info.IsDir() {
			found = append(found, absExePath)
		}
	}
	return found, nil
}

// FindOtherExecutablesInPath returns all executables named exeName found in PATH
// excluding the currently running executable (currentExe).
//
// The comparison is case-insensitive to match Windows path semantics.
func FindOtherExecutablesInPath(currentExe string, exeName string) ([]string, error) {
	currentExeAbs, _ := filepath.Abs(currentExe)

	paths, err := FindExecutablesInPath(exeName)
	if err != nil {
		return nil, err
	}

	var others []string
	for _, path := range paths {
		absPath, _ := filepath.Abs(path)
		if !strings.EqualFold(absPath, currentExeAbs) {
			others = append(others, absPath)
		}
	}
	return others, nil
}

