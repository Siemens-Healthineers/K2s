// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/siemens-healthineers/k2s/internal/windows/users"
)

type winUserProvider struct{}

func (*winUserProvider) FindByName(name string) (WinUser, error) {
	return users.FindByName(name)
}

func (*winUserProvider) FindById(id string) (WinUser, error) {
	return users.FindById(id)
}

func (*winUserProvider) Current() (WinUser, error) {
	return users.Current()
}
