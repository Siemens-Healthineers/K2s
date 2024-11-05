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
	return "C:\\"
}

// ReplaceTildeWithHomeDir replaces the tilde ('~') in the given path with the current user's home directory path.
func ReplaceTildeWithHomeDir(path string) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to determine user home dir: %w", err)
	}
	return strings.Replace(filepath.Clean(path), "~", homeDir, 1), nil
}
