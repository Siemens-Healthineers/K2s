// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package acl

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type acl struct {
	exec common.CmdExecutor
}

func NewAcl(exec common.CmdExecutor) *acl {
	return &acl{
		exec: exec,
	}
}

func (acl *acl) SetOwner(path string, owner string) error {
	slog.Debug("Setting owner", "path", path, "owner", owner)

	if err := acl.exec.ExecuteCmd("icacls", path, "/t", "/setowner", owner); err != nil {
		return fmt.Errorf("could not set owner '%s' of '%s': %w", owner, path, err)
	}
	return nil
}

func (acl *acl) RemoveInheritance(path string) error {
	slog.Debug("Removing security inheritance", "path", path)

	if err := acl.exec.ExecuteCmd("icacls", path, "/t", "/inheritance:d"); err != nil {
		return fmt.Errorf("could not remove security inheritance from '%s': %w", path, err)
	}
	return nil
}

func (acl *acl) GrantFullAccess(path string, username string) error {
	slog.Debug("Granting full access", "path", path, "username", username)

	accessParam := fmt.Sprintf("%s:(F)", username)

	if err := acl.exec.ExecuteCmd("icacls", path, "/t", "/grant", accessParam); err != nil {
		return fmt.Errorf("could not grant user '%s' full access to '%s': %w", username, path, err)
	}
	return nil
}

func (acl *acl) RevokeAccess(path string, username string) error {
	slog.Debug("Revoking access", "path", path, "username", username)

	if err := acl.exec.ExecuteCmd("icacls", path, "/t", "/remove:g", username); err != nil {
		return fmt.Errorf("could not revoke access to '%s' for '%s': %w", path, username, err)
	}
	return nil
}
