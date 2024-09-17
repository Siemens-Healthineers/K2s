// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package fs

import (
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/host"
)

type fileSystem struct{}

func NewFileSystem() *fileSystem {
	return &fileSystem{}
}

func (*fileSystem) PathExists(path string) bool {
	return host.PathExists(path)
}

func (*fileSystem) AppendToFile(path string, text string) error {
	return host.AppendToFile(path, text)
}

func (*fileSystem) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (*fileSystem) WriteFile(path string, data []byte) error {
	return os.WriteFile(path, data, os.ModePerm)
}

func (*fileSystem) RemovePaths(files ...string) error {
	return host.RemovePaths(files...)
}

func (*fileSystem) RemoveAll(path string) error {
	return os.RemoveAll(path)
}

func (*fileSystem) CreateDirIfNotExisting(path string) error {
	return host.CreateDirIfNotExisting(path)
}

func (*fileSystem) MatchingFiles(pattern string) (matches []string, err error) {
	return filepath.Glob(pattern)
}
