// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

type controlPlane interface {
	Name() string
	Exec(cmd string) error
	CopyTo(source string, target string) error
	CopyFrom(source string, target string) error
}

type cmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}

type commonAccessGranter struct {
	cmdExecutor  cmdExecutor
	controlPlane controlPlane
}

const (
	k2sPrefix = "k2s-"
)
