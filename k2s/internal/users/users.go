// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"
	"os/user"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/nodes"
	"github.com/siemens-healthineers/k2s/internal/ssh"
)

type accessGranter interface {
	GrantAccess(winUser user.User, k2sUserName string) error
}

type UserNotFoundErr string

type UsersManagement struct {
	sshAccessGranter accessGranter
	k8sAccessGranter accessGranter
}

func NewUsersManagement(controlPlaneName string, cfg *config.Config, confirmOverwrite func() bool, cmdExecutor cmdExecutor) (*UsersManagement, error) {
	ssh := ssh.NewSsh(cmdExecutor)
	controlPlane, err := nodes.NewControlPlane(ssh, cfg, controlPlaneName)
	if err != nil {
		return nil, fmt.Errorf("could not create control-plane access: %w", err)
	}

	accessGranter := &commonAccessGranter{cmdExecutor: cmdExecutor, controlPlane: controlPlane}

	return &UsersManagement{
		sshAccessGranter: newSshAccessGranter(accessGranter, confirmOverwrite, filepath.Base(cfg.Host.SshDir)),
		k8sAccessGranter: newK8sAccessGranter(accessGranter, cfg.Host.KubeConfigDir),
	}, nil
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (m *UsersManagement) AddUserByName(name string) error {
	winUser, err := user.Lookup(name)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by name '%s'", name))
	}

	return m.addUser(*winUser)
}

func (m *UsersManagement) AddUserById(id string) error {
	winUser, err := user.LookupId(id)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by id '%s'", id))
	}

	return m.addUser(*winUser)
}

func (m *UsersManagement) addUser(winUser user.User) error {
	slog.Debug("Adding Windows user", "username", winUser.Username, "id", winUser.Uid, "homedir", winUser.HomeDir, "group-id", winUser.Gid) // omit user's display name for privacy reasons

	k2sUserName := k2sPrefix + strings.ReplaceAll(winUser.Username, "\\", "-")

	if err := m.sshAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user SSH access to control-plane: %w", err)
	}
	if err := m.k8sAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user K8s access: %w", err)
	}
	return nil
}
