// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package users

import (
	"github.com/siemens-healthineers/k2s/internal/users/adapters/winacl"
	"github.com/siemens-healthineers/k2s/internal/users/adapters/winusers"
)

// PlatformUsersProvider returns the Windows-specific user lookup provider.
func PlatformUsersProvider() UsersProvider {
	return winusers.NewWinUsersProvider()
}

// PlatformACLProvider returns the Windows-specific ACL provider.
func PlatformACLProvider() ACLProvider {
	return winacl.NewACLProvider()
}
