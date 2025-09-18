// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	ssh_contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
	users_contracts "github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/api"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/cert"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/decoding"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/core/users/controlplane"
	"github.com/siemens-healthineers/k2s/internal/core/users/controlplane/keyauth"
	"github.com/siemens-healthineers/k2s/internal/core/users/controlplane/knownhosts"
	"github.com/siemens-healthineers/k2s/internal/core/users/naming"
	"github.com/siemens-healthineers/k2s/internal/core/users/validation"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/providers/http"
	"github.com/siemens-healthineers/k2s/internal/providers/kubectl"
	kubeconfig_adapter "github.com/siemens-healthineers/k2s/internal/users/adapters/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/users/adapters/ssh"
	"github.com/siemens-healthineers/k2s/internal/users/adapters/winacl"
	"github.com/siemens-healthineers/k2s/internal/users/adapters/winusers"
)

type UsersProvider interface {
	CurrentUser() (*users_contracts.OSUser, error)
	FindByName(name string) (*users_contracts.OSUser, error)
	FindById(id string) (*users_contracts.OSUser, error)
}

type AddUserIntegration struct {
	usersProvider UsersProvider
	userAdmission *users.UserAdmission
}

func WinUsersProvider() UsersProvider {
	return winusers.NewWinUsersProvider()
}

func NewAddUserIntegration(k2sConfig *config.K2sConfig, runtimeConfig *config.K2sRuntimeConfig, usersProvider UsersProvider) *AddUserIntegration {
	connectionOptions := ssh_contracts.ConnectionOptions{
		RemoteUser:        definitions.SSHRemoteUser,
		IpAddress:         k2sConfig.ControlPlane().IpAddress(),
		Port:              definitions.SSHDefaultPort,
		SshPrivateKeyPath: k2sConfig.Host().SshConfig().CurrentPrivateKeyPath(),
		Timeout:           definitions.SSHDefaultTimeout,
	}

	sshProvider := ssh.NewSSHProvider(connectionOptions)
	aclProvider := winacl.NewACLProvider()
	keyAuthorizer := keyauth.NewKeyAuthorizer(sshProvider)
	knownHostsCopier := knownhosts.NewKnownHostsCopier(k2sConfig.Host().SshConfig())
	controlPlaneAdmission := controlplane.NewControlPlaneAdmission(k2sConfig, sshProvider, aclProvider, keyAuthorizer, knownHostsCopier)
	kubectl := kubectl.NewKubectl(k2sConfig.Host())
	kubeconfigReaderAdapter := kubeconfig_adapter.NewKubeconfigReader(k2sConfig.Host().KubeConfig())
	clusterFinder := kubeconfig_adapter.NewClusterFinder(runtimeConfig.ClusterConfig())
	kubeconfigWriter := kubeconfig.NewKubeconfigWriter(k2sConfig.Host().KubeConfig(), kubectl)
	kubeconfigCopier := kubeconfig.NewKubeconfigCopier(kubeconfigReaderAdapter, clusterFinder, kubeconfigWriter)
	kubeconfigResolver := kubeconfig.NewKubeconfigResolver(k2sConfig.Host().KubeConfig())
	remoteCertCreator := cert.NewRemoteCertCreator(sshProvider)
	certGenerator := cert.NewCertGenerator(remoteCertCreator, sshProvider)
	credentialsDecoder := decoding.NewCredentialsDecoder()
	credentialsFinder := kubeconfig_adapter.NewCredentialsFinder()
	restClient := http.NewRestClient()
	apiAccessVerifier := api.NewApiAccessVerifier(restClient)
	kubeconfigReader := kubeconfig.NewKubeconfigReader(k2sConfig.Host().KubeConfig(), kubeconfigReaderAdapter, credentialsFinder)
	accessVerifier := cluster.NewClusterAccessVerifier(kubeconfigReader, credentialsDecoder, apiAccessVerifier)
	clusterAdmission := cluster.NewClusterAdmission(runtimeConfig.ClusterConfig(), kubeconfigResolver, kubeconfigCopier, kubeconfigWriter, kubeconfigReader, certGenerator, accessVerifier)
	k2sUserNameProvider := naming.NewK2sUserNameProvider()
	userValidator := validation.NewUserValidator(usersProvider)

	return &AddUserIntegration{
		usersProvider: usersProvider,
		userAdmission: users.NewUserAdmission(userValidator, k2sUserNameProvider, controlPlaneAdmission, clusterAdmission),
	}
}

func (a *AddUserIntegration) AddById(userId string) error {
	user, err := a.usersProvider.FindById(userId)
	if err != nil {
		return err
	}
	return a.userAdmission.Add(user)
}

func (a *AddUserIntegration) AddByName(userName string) error {
	user, err := a.usersProvider.FindByName(userName)
	if err != nil {
		return err
	}
	return a.userAdmission.Add(user)
}
