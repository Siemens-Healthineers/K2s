// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package osusers

import (
	"fmt"
	"os/user"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
)

func CurrentUser() (*users.OSUser, error) {
	u, err := user.Current()
	if err != nil {
		return nil, fmt.Errorf("failed to get current user: %w", err)
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func FindByName(name string) (*users.OSUser, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("user '%s' not found: %w", name, err)
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func FindById(id string) (*users.OSUser, error) {
	u, err := user.LookupId(id)
	if err != nil {
		return nil, fmt.Errorf("user with id '%s' not found: %w", id, err)
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}
