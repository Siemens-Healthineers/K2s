// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"

	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/nodes"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/ssh"
	"github.com/siemens-healthineers/k2s/internal/windows/acl"
)

type userProvider interface {
	FindByName(name string) (WinUser, error)
	FindById(id string) (WinUser, error)
}

type userAdder interface {
	Add(winUser WinUser) error
}

type UserNotFoundErr string

type UsersManagementConfig struct {
	ControlPlaneName string
	Config           *config.Config
	StdWriter        host.StdWriter
}

type usersManagement struct {
	userProvider userProvider
	userAdder    userAdder
}

func NewUsersManagement(config *UsersManagementConfig) (*usersManagement, error) {
	cmdExecutor := host.NewCmdExecutor(config.StdWriter)

	ssh := ssh.NewSsh(cmdExecutor)
	controlPlane, err := nodes.NewControlPlane(ssh, config.Config, config.ControlPlaneName)
	if err != nil {
		return nil, fmt.Errorf("could not create control-plane access: %w", err)
	}

	accessGranter := &commonAccessGranter{
		exec:         cmdExecutor,
		controlPlane: controlPlane,
		fs:           &winFileSystem{},
	}

	userProvider := &winUserProvider{}
	sshAccessGranter := newSshAccessGranter(accessGranter, config.Config.Host.SshDir, userProvider)
	k8sAccessGranter := newK8sAccessGranter(accessGranter, config.Config.Host.KubeConfigDir)
	userAdder := NewWinUserAdder(sshAccessGranter, k8sAccessGranter, CreateK2sUserName)

	return &usersManagement{
		userProvider: userProvider,
		userAdder:    userAdder,
	}, nil
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (m *usersManagement) AddUserByName(name string) error {
	winUser, err := m.userProvider.FindByName(name)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}

	return m.userAdder.Add(winUser)
}

func (m *usersManagement) AddUserById(id string) error {
	winUser, err := m.userProvider.FindById(id)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}

	return m.userAdder.Add(winUser)
}

func newSshAccessGranter(accessGranter *commonAccessGranter, sshDir string, userFinder currentUserFinder) accessGranter {
	return &sshAccessGranter{
		commonAccessGranter: accessGranter,
		sshKeyGen:           ssh.NewSshKeyGen(accessGranter.exec, accessGranter.fs),
		accessControl:       acl.NewAcl(accessGranter.exec),
		adminSshDir:         sshDir,
		userFinder:          userFinder,
	}
}

func newK8sAccessGranter(accessGranter *commonAccessGranter, kubeconfigDir string) accessGranter {
	return &k8sAccessGranter{
		commonAccessGranter: accessGranter,
		kubeconfigDir:       kubeconfigDir,
	}
}
