// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

type User interface {
	Name() string
	HomeDir() string
}

type CmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}

const K2sPrefix = "k2s-"
