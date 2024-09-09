// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"os"

	"github.com/siemens-healthineers/k2s/internal/host"
)

type winFileSystem struct{}

func (*winFileSystem) PathExists(path string) bool {
	return host.PathExists(path)
}

func (*winFileSystem) AppendToFile(path string, text string) error {
	return host.AppendToFile(path, text)
}

func (*winFileSystem) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (*winFileSystem) WriteFile(path string, data []byte) error {
	return os.WriteFile(path, data, os.ModePerm)
}

func (*winFileSystem) RemovePaths(files ...string) error {
	return host.RemovePaths(files...)
}

func (*winFileSystem) CreateDirIfNotExisting(path string) error {
	return host.CreateDirIfNotExisting(path)
}
