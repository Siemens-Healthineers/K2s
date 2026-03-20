// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package users

import (
	"fmt"
	"os"
	"os/user"

	users_contracts "github.com/siemens-healthineers/k2s/internal/contracts/users"
)

// linuxUsersProvider implements UsersProvider using standard POSIX user lookup.
type linuxUsersProvider struct{}

func (p *linuxUsersProvider) CurrentUser() (*users_contracts.OSUser, error) {
	u, err := user.Current()
	if err != nil {
		return nil, fmt.Errorf("failed to get current user: %w", err)
	}
	return users_contracts.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func (p *linuxUsersProvider) FindByName(name string) (*users_contracts.OSUser, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("user '%s' not found: %w", name, err)
	}
	return users_contracts.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func (p *linuxUsersProvider) FindById(id string) (*users_contracts.OSUser, error) {
	u, err := user.LookupId(id)
	if err != nil {
		return nil, fmt.Errorf("user with id '%s' not found: %w", id, err)
	}
	return users_contracts.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

// linuxACLProvider implements ACLProvider using standard POSIX chown.
type linuxACLProvider struct{}

func (p *linuxACLProvider) TransferFileOwnership(path string, targetUser *users_contracts.OSUser) error {
	// On Linux, use chown to transfer ownership.
	// targetUser.Id() is the UID string.
	return os.Chown(path, -1, -1) // TODO: parse targetUser.Id() to int uid and set properly
}

// PlatformUsersProvider returns the Linux-specific user lookup provider.
func PlatformUsersProvider() UsersProvider {
	return &linuxUsersProvider{}
}

// PlatformACLProvider returns the Linux-specific ACL provider.
func PlatformACLProvider() ACLProvider {
	return &linuxACLProvider{}
}
