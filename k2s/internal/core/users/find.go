// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/siemens-healthineers/k2s/internal/windows/users"
)

type winUserFinder struct{}

func (*winUserFinder) FindByName(name string) (*users.WinUser, error) {
	return users.FindByName(name)
}

func (*winUserFinder) FindById(id string) (*users.WinUser, error) {
	return users.FindById(id)
}

func (*winUserFinder) Current() (*users.WinUser, error) {
	return users.Current()
}
