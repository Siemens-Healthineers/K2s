// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"
	"os"
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

type UsersManagementConfig struct {
	ControlPlaneName     string
	Config               *config.Config
	ConfirmOverwriteFunc func() bool
	CmdExecutor          cmdExecutor
	FileSystem           fileSystem
}

const (
	systemAccountName     = "SYSTEM"
	systemAccountFullName = "NT AUTHORITY\\" + systemAccountName
	systemAccountId       = "S-1-5-18"
)

var systemAccountHomeDir = filepath.Join(os.Getenv("SYSTEMROOT"), "System32\\config\\systemprofile")

func NewUsersManagement(config *UsersManagementConfig) (*UsersManagement, error) {
	ssh := ssh.NewSsh(config.CmdExecutor)
	controlPlane, err := nodes.NewControlPlane(ssh, config.Config, config.ControlPlaneName)
	if err != nil {
		return nil, fmt.Errorf("could not create control-plane access: %w", err)
	}

	accessGranter := &commonAccessGranter{
		exec:         config.CmdExecutor,
		controlPlane: controlPlane,
		fs:           config.FileSystem,
	}

	return &UsersManagement{
		sshAccessGranter: newSshAccessGranter(accessGranter, config.ConfirmOverwriteFunc, config.Config.Host.SshDir, user.Current),
		k8sAccessGranter: newK8sAccessGranter(accessGranter, config.Config.Host.KubeConfigDir),
	}, nil
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (m *UsersManagement) AddUserByName(name string) error {
	winUser, err := lookupUserByName(name)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by name '%s'", name))
	}

	return m.addUser(*winUser)
}

func (m *UsersManagement) AddUserById(id string) error {
	winUser, err := lookupUserById(id)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by id '%s'", id))
	}

	return m.addUser(*winUser)
}

func (m *UsersManagement) addUser(winUser user.User) error {
	// omit user's display name for privacy reasons
	slog.Debug("Adding Windows user", "username", winUser.Username, "id", winUser.Uid, "homedir", winUser.HomeDir, "group-id", winUser.Gid)

	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(winUser.Username, " ", "-"), "\\", "-")
	k2sUserName := k2sPrefix + beautifiedUsername

	if err := m.sshAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user SSH access to control-plane: %w", err)
	}
	if err := m.k8sAccessGranter.GrantAccess(winUser, k2sUserName); err != nil {
		return fmt.Errorf("cannot grant Windows user K8s access: %w", err)
	}
	return nil
}

func lookupUserByName(name string) (*user.User, error) {
	if isSystemAccountName(name) {
		return newSystemUser(), nil
	}
	return user.Lookup(name)
}

func lookupUserById(id string) (*user.User, error) {
	if isSystemAccountId(id) {
		return newSystemUser(), nil
	}
	return user.LookupId(id)
}

func isSystemAccountName(name string) bool {
	return strings.EqualFold(name, systemAccountName) || strings.EqualFold(name, systemAccountFullName)
}

func isSystemAccountId(id string) bool {
	return strings.EqualFold(id, systemAccountId)
}

func newSystemUser() *user.User {
	return &user.User{
		Uid:      systemAccountId,
		Username: systemAccountFullName,
		HomeDir:  systemAccountHomeDir,
	}
}
