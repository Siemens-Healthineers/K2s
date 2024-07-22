// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

type cmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}
