// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/siemens-healthineers/k2s/internal/windows/users"
)

type userFinder interface {
	FindByName(name string) (*users.WinUser, error)
	FindById(id string) (*users.WinUser, error)
}

type userAdder interface {
	Add(winUser *users.WinUser) error
}

type UserNotFoundErr string

type UsersManagement struct {
	userFinder userFinder
	userAdder  userAdder
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (m *UsersManagement) AddUserByName(name string) error {
	winUser, err := m.userFinder.FindByName(name)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}

	return m.userAdder.Add(winUser)
}

func (m *UsersManagement) AddUserById(id string) error {
	winUser, err := m.userFinder.FindById(id)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}

	return m.userAdder.Add(winUser)
}
