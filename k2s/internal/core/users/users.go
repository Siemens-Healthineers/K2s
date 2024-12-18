// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/node"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh/keygen"
	"github.com/siemens-healthineers/k2s/internal/core/users/acl"
	"github.com/siemens-healthineers/k2s/internal/core/users/common"
	"github.com/siemens-healthineers/k2s/internal/core/users/controlplane"
	"github.com/siemens-healthineers/k2s/internal/core/users/fs"
	"github.com/siemens-healthineers/k2s/internal/core/users/http"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/cluster"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/core/users/winusers"
)

type UserProvider interface {
	FindByName(name string) (*winusers.User, error)
	FindById(id string) (*winusers.User, error)
	Current() (*winusers.User, error)
}

type userAdder interface {
	Add(winUser common.User, currentUserName string) error
}

type UserNotFoundErr string

type usersManagement struct {
	userProvider UserProvider
	userAdder    userAdder
}

type kubeconfWriterFactory struct {
	exec common.CmdExecutor
}

func DefaultUserProvider() UserProvider {
	return winusers.NewWinUserProvider()
}

func NewUsersManagement(cfg *config.Config, cmdExecutor common.CmdExecutor, userProvider UserProvider) (*usersManagement, error) {
	controlePlaneCfg, found := lo.Find(cfg.Nodes, func(node config.NodeConfig) bool {
		return node.IsControlPlane
	})
	if !found {
		return nil, errors.New("could not find control-plane node config")
	}

	kubeconfigWriterFactory := &kubeconfWriterFactory{
		exec: cmdExecutor,
	}

	sshOptions := ssh.ConnectionOptions{
		RemoteUser: "remote",
		IpAddress:  controlePlaneCfg.IpAddress,
		Port:       ssh.DefaultPort,
		SshKeyPath: ssh.SshKeyPath(cfg.Host.SshDir),
		Timeout:    ssh.DefaultTimeout,
	}

	fileSystem := fs.NewFileSystem()
	keygenExec := keygen.NewSshKeyGen(cmdExecutor, fileSystem)
	aclExec := acl.NewAcl(cmdExecutor)
	restClient := http.NewRestClient()
	kubeconfigReader := kubeconfig.NewKubeconfigReader()
	controlPlaneAccess := controlplane.NewControlPlaneAccess(fileSystem, keygenExec, node.Exec, node.Copy, sshOptions, aclExec, cfg.Host.SshDir, controlePlaneCfg.IpAddress)
	clusterAccess := cluster.NewClusterAccess(restClient)
	k8sAccess := k8s.NewK8sAccess(node.Exec, node.Copy, sshOptions, fileSystem, clusterAccess, kubeconfigWriterFactory, kubeconfigReader, cfg.Host.KubeConfigDir)
	userAdder := NewWinUserAdder(controlPlaneAccess, k8sAccess, CreateK2sUserName)

	return &usersManagement{
		userProvider: userProvider,
		userAdder:    userAdder,
	}, nil
}

func (k *kubeconfWriterFactory) NewKubeconfigWriter(filePath string) k8s.KubeconfigWriter {
	return kubeconfig.NewKubeconfigWriter(filePath, k.exec)
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (m *usersManagement) AddUserByName(name string) error {
	winUser, err := m.userProvider.FindByName(name)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}
	return m.add(winUser)
}

func (m *usersManagement) AddUserById(id string) error {
	winUser, err := m.userProvider.FindById(id)
	if err != nil {
		return UserNotFoundErr(err.Error())
	}
	return m.add(winUser)
}

func (m *usersManagement) add(winUser *winusers.User) error {
	slog.Debug("Adding Windows user", "name", winUser.Name(), "id", winUser.Id())

	current, err := m.userProvider.Current()
	if err != nil {
		return fmt.Errorf("could not determine current Windows user: %w", err)
	}

	slog.Debug("Current Windows user determined", "name", current.Name(), "id", current.Id())

	if winUser.Id() == current.Id() {
		return fmt.Errorf("cannot overwrite access of current Windows user (name='%s', id='%s')", current.Name(), current.Id())
	}

	return m.userAdder.Add(winUser, current.Name())
}
