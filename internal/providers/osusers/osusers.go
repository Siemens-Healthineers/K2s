// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package osusers

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
)

type OSUserProvider struct{}

func NewOSUserProvider() *OSUserProvider {
	return &OSUserProvider{}
}

func (*OSUserProvider) FindByName(name string) (*users.OSUser, error) {
	return FindByName(name)
}

func (*OSUserProvider) FindById(id string) (*users.OSUser, error) {
	return FindById(id)
}

func (*OSUserProvider) CurrentUser() (*users.OSUser, error) {
	return CurrentUser()
}
