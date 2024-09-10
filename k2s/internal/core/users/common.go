// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

type controlPlane interface {
	Name() string
	IpAddress() string
	Exec(cmd string) error
	CopyTo(source string, target string) error
	CopyFrom(source string, target string) error
}

type cmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}

type fileSystem interface {
	PathExists(path string) bool
	AppendToFile(path string, text string) error
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, data []byte) error
	RemovePaths(paths ...string) error
	CreateDirIfNotExisting(path string) error
}

type commonAccessGranter struct {
	exec         cmdExecutor
	controlPlane controlPlane
	fs           fileSystem
}

const (
	k2sPrefix = "k2s-"
)
