// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/windows/users"
)

type accessGranter interface {
	GrantAccess(winUser *users.WinUser, k2sUserName string) error
}

type winUserAdder struct {
	sshAccessGranter  accessGranter
	k8sAccessGranter  accessGranter
	createK2sUserName func(winUserName string) string
}

func (a *winUserAdder) Add(winUser *users.WinUser) error {
	slog.Debug("Adding Windows user", "username", winUser.Username, "id", winUser.UserId, "homedir", winUser.HomeDir, "group-id", winUser.GroupId)

	k2sUserName := a.createK2sUserName(winUser.Username)

	if err := a.sshAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user SSH access to control-plane: %w", err)
	}
	if err := a.k8sAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user K8s access: %w", err)
	}
	return nil
}
