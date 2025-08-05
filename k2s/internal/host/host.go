// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package host

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// SystemDrive returns hard-coded 'C:\' drive string instead of the actual system drive, because some containers are also hard-coded to this drive.
//
// Note: This string has already the backslash '\' attached, because Go's filepath.Join() would otherwise not be able to correctly join the drive and other path components
// (see https://github.com/golang/go/issues/26953).
func SystemDrive() string {
	// TODO: move to windows package
	return "C:\\"
}

// ResolveTildePrefixForCurrentUser replaces the leading tilde ('~') in the given path with the current user's home directory.
func ResolveTildePrefixForCurrentUser(path string) (string, error) {
	if !strings.HasPrefix(path, "~") {
		return path, nil
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to determine user home dir: %w", err)
	}
	return ResolveTildePrefix(path, homeDir), nil
}

// ResolveTildePrefix replaces the first tilde ('~') in the given path with the given path for replacement.
func ResolveTildePrefix(pathWithTilde, pathToReplaceTildeWith string) string {
	return filepath.Clean(strings.Replace(pathWithTilde, "~", pathToReplaceTildeWith, 1))
}
