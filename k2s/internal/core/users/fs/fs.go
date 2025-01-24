// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package fs

import (
	"os"
	"path/filepath"

	kos "github.com/siemens-healthineers/k2s/internal/os"
)

type fileSystem struct{}

func NewFileSystem() *fileSystem {
	return &fileSystem{}
}

func (*fileSystem) PathExists(path string) bool {
	return kos.PathExists(path)
}

func (*fileSystem) AppendToFile(path string, text string) error {
	return kos.AppendToFile(path, text)
}

func (*fileSystem) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (*fileSystem) WriteFile(path string, data []byte) error {
	return os.WriteFile(path, data, os.ModePerm)
}

func (*fileSystem) RemovePaths(files ...string) error {
	return kos.RemovePaths(files...)
}

func (*fileSystem) RemoveAll(path string) error {
	return os.RemoveAll(path)
}

func (*fileSystem) CreateDirIfNotExisting(path string) error {
	return kos.CreateDirIfNotExisting(path)
}

func (*fileSystem) MatchingFiles(pattern string) (matches []string, err error) {
	return filepath.Glob(pattern)
}
