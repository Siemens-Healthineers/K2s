// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package winacl

import (
	"fmt"
	"log/slog"

	acl_pkg "github.com/hectane/go-acl"
	contracts "github.com/siemens-healthineers/k2s/internal/contracts/users"
	"golang.org/x/sys/windows"
)

const (
	replaceExistingEntries = true
	dontInheritACEs        = false
	adminUserGroup         = "Administrators"
)

func TransferFileOwnership(path string, user *contracts.OSUser) error {
	slog.Debug("Transferring file ownership", "path", path, "user", user.Name())

	if err := acl_pkg.Apply(
		path,
		replaceExistingEntries,
		dontInheritACEs,
		acl_pkg.GrantName(windows.GENERIC_ALL, user.Name()),
		acl_pkg.GrantName(windows.GENERIC_ALL, adminUserGroup),
	); err != nil {
		return fmt.Errorf("failed to transfer ownership of '%s' to user '%s': %w", path, user.Name(), err)
	}

	slog.Debug("File ownership transferred", "path", path, "user", user.Name())
	return nil
}
