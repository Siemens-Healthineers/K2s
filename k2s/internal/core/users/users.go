// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"

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
	bkc "github.com/siemens-healthineers/k2s/internal/k8s/kubeconfig"
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

type nodeAccess struct {
	sshOptions ssh.ConnectionOptions
	sshDir     string
}

type kubeconfigReader struct{}

func DefaultUserProvider() UserProvider {
	return winusers.NewWinUserProvider()
}

func NewUsersManagement(cfg config.ConfigReader, cmdExecutor common.CmdExecutor, userProvider UserProvider) (*usersManagement, error) {
	kubeconfigWriterFactory := &kubeconfWriterFactory{
		exec: cmdExecutor,
	}

	sshOptions := ssh.ConnectionOptions{
		RemoteUser: "remote",
		IpAddress:  cfg.ControlPlane().IpAddress(),
		Port:       ssh.DefaultPort,
		SshKeyPath: ssh.SshKeyPath(cfg.Host().SshDir()),
		Timeout:    ssh.DefaultTimeout,
	}

	fileSystem := fs.NewFileSystem()
	keygenExec := keygen.NewSshKeyGen(cmdExecutor, fileSystem)
	aclExec := acl.NewAcl(cmdExecutor)
	restClient := http.NewRestClient()
	nodeAccess := &nodeAccess{sshOptions: sshOptions, sshDir: cfg.Host().SshDir()}
	controlPlaneAccess := controlplane.NewControlPlaneAccess(fileSystem, keygenExec, nodeAccess, aclExec, cfg.ControlPlane().IpAddress())
	clusterAccess := cluster.NewClusterAccess(restClient)
	k8sAccess := k8s.NewK8sAccess(nodeAccess, fileSystem, clusterAccess, kubeconfigWriterFactory, &kubeconfigReader{}, cfg.Host().KubeConfigDir())
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

func (a *nodeAccess) Copy(copyOptions node.CopyOptions) error {
	return node.Copy(copyOptions, a.sshOptions)
}

func (a *nodeAccess) Exec(command string) error {
	return node.Exec(command, a.sshOptions)
}

func (a *nodeAccess) HostSshDir() string {
	return a.sshDir
}

func (*kubeconfigReader) ReadFile(path string) (*bkc.KubeconfigRoot, error) {
	return bkc.ReadFile(path)
}
