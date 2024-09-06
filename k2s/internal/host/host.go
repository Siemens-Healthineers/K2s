// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host

import (
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
)

// SystemDrive returns hard-coded 'C:\' drive string instead of the actual system drive, because some containers are also hard-coded to this drive.
//
// Note: This string has already the backslash '\' attached, because Go's filepath.Join() would otherwise not be able to correctly join the drive and other path components
// (see https://github.com/golang/go/issues/26953).
func SystemDrive() string {
	return "C:\\"
}

func CreateDirIfNotExisting(dir string) error {
	_, err := os.Stat(dir)
	if !os.IsNotExist(err) {
		return err
	}

	if err = os.MkdirAll(dir, os.ModePerm); err != nil {
		return err
	}

	return nil
}

func ExecutableDir() (string, error) {
	exePath, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exePath), nil
}

func PathExists(path string) bool {
	_, err := os.Stat(path)
	if err == nil {
		slog.Debug("Path exists", "path", path)
		return true
	}

	if !errors.Is(err, fs.ErrNotExist) {
		slog.Error("could not check existence of path", "path", path, "error", err)
	}
	return false
}
