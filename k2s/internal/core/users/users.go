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

type UsersManagementConfig struct {
	ControlPlaneName     string
	Config               *config.Config
	ConfirmOverwriteFunc func() bool
	StdWriter            host.StdWriter
}

func NewUsersManagement(config *UsersManagementConfig) (*UsersManagement, error) {
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

	userFinder := &winUserFinder{}

	return &UsersManagement{
		userFinder: userFinder,
		userAdder: &winUserAdder{
			sshAccessGranter:  newSshAccessGranter(accessGranter, config.ConfirmOverwriteFunc, config.Config.Host.SshDir, userFinder),
			k8sAccessGranter:  newK8sAccessGranter(accessGranter, config.Config.Host.KubeConfigDir),
			createK2sUserName: CreateK2sUserName,
		},
	}, nil
}

func newSshAccessGranter(accessGranter *commonAccessGranter, confirmOverwrite func() bool, sshDir string, userFinder currentUserFinder) accessGranter {
	return &sshAccessGranter{
		commonAccessGranter: accessGranter,
		confirmOverwrite:    confirmOverwrite,
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
