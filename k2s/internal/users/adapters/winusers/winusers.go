// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package winusers

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/providers/winusers"
)

type WinUsersProvider struct{}

func NewWinUsersProvider() *WinUsersProvider {
	return &WinUsersProvider{}
}

func (*WinUsersProvider) CurrentUser() (*users.OSUser, error) {
	return winusers.Current()
}

func (*WinUsersProvider) FindByName(name string) (*users.OSUser, error) {
	return winusers.FindByName(name)
}

func (*WinUsersProvider) FindById(id string) (*users.OSUser, error) {
	return winusers.FindById(id)
}
