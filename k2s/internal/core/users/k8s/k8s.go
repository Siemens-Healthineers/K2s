// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package k8s

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/cluster"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/kubeconfig"
)

type KubeconfigWriter interface {
	FilePath() string
	SetCluster(clusterConfig *kubeconfig.ClusterEntry) error
	SetCredentials(username, certPath, keyPath string) error
	SetContext(context, username, clusterName string) error
	UseContext(context string) error
}

type ssh interface {
	Exec(cmd string) error
}

type scp interface {
	CopyFromRemote(source string, target string) error
}

type fileSystem interface {
	CreateDirIfNotExisting(path string) error
	RemoveAll(path string) error
}

type clusterAccess interface {
	VerifyAccess(userParam *cluster.UserParam, clusterParam *cluster.ClusterParam) error
}

type kubeconfigReader interface {
	ReadFile(path string) (*kubeconfig.KubeconfigRoot, error)
}

type kubeconfigWriterFactory interface {
	NewKubeconfigWriter(filePath string) KubeconfigWriter
}

type k8sAccess struct {
	ssh                     ssh
	scp                     scp
	fs                      fileSystem
	kubeconfigDir           string
	clusterAccess           clusterAccess
	kubeconfigWriterFactory kubeconfigWriterFactory
	kubeconfigReader        kubeconfigReader
	k2sGroupName            string
}

const (
	kubeconfigName  = "config"
	k2sClusterName  = "kubernetes"
	k2sGroupSuffix  = "users"
	tempCertDirName = "k2s-user-certs"
	remoteCertDir   = "/tmp/" + tempCertDirName
	privateKeyBits  = 2048
	certValidDays   = 365
	k8sCaCert       = "/etc/kubernetes/pki/ca.crt"
	k8sCaKey        = "/etc/kubernetes/pki/ca.key"
)

func NewK8sAccess(ssh ssh, scp scp, fs fileSystem, clusterAccess clusterAccess, kubeconfigWriterFactory kubeconfigWriterFactory, kubeconfigReader kubeconfigReader, kubeconfigDir string) *k8sAccess {
	return &k8sAccess{
		ssh:                     ssh,
		scp:                     scp,
		fs:                      fs,
		clusterAccess:           clusterAccess,
		kubeconfigWriterFactory: kubeconfigWriterFactory,
		kubeconfigReader:        kubeconfigReader,
		kubeconfigDir:           kubeconfigDir,
		k2sGroupName:            common.K2sPrefix + k2sGroupSuffix,
	}
}

func (g *k8sAccess) GrantAccessTo(user common.User, k2sUserName string) error {
	kubeconfigWriter, err := g.deriveKubeconfigFromAdmin(user)
	if err != nil {
		return fmt.Errorf("could not derive new kubeconfig from admin's config: %w", err)
	}

	certPath, keyPath, err := g.createK8sUserCert(k2sUserName, kubeconfigWriter.FilePath())
	if err != nil {
		return fmt.Errorf("could not create a new user cert signed by K8s: %w", err)
	}

	if err := g.addUserAccessToKubeconfig(k2sUserName, certPath, keyPath, kubeconfigWriter); err != nil {
		return fmt.Errorf("could not add new K8s access to new user's kubeconfig: %w", err)
	}
	return nil
}

func (g *k8sAccess) deriveKubeconfigFromAdmin(user common.User) (KubeconfigWriter, error) {
	kubeconfigDir, err := g.initKubeconfigDir(user.HomeDir())
	if err != nil {
		return nil, fmt.Errorf("could not initialize kubeconfig dir for '%s': %w", user.Name(), err)
	}

	k2sClusterConfig, err := g.readAdminsK2sClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("could not read K2s cluster config from admin's kubeconfig: %w", err)
	}

	kubeconfigPath := filepath.Join(kubeconfigDir, kubeconfigName)

	kubeconfigWriter := g.kubeconfigWriterFactory.NewKubeconfigWriter(kubeconfigPath)

	if err := kubeconfigWriter.SetCluster(k2sClusterConfig); err != nil {
		return nil, fmt.Errorf("could not set K2s cluster config for new user in kubeconfig: %w", err)
	}
	return kubeconfigWriter, nil
}

func (g *k8sAccess) createK8sUserCert(k2sUserName, kubeconfigPath string) (certPath, keyPath string, err error) {
	kubeconfigDir := filepath.Dir(kubeconfigPath)
	certName, keyName, err := g.createUserCertOnControlPlane(k2sUserName)
	if err != nil {
		return "", "", fmt.Errorf("could not generate cert for '%s' signed by K8s CA: %w", k2sUserName, err)
	}

	if err := g.fetchUserCertFromControlPlane(kubeconfigDir); err != nil {
		return "", "", fmt.Errorf("could not extract user cert and key from control-plane: %w", err)
	}
	localCertDir := filepath.Join(kubeconfigDir, tempCertDirName)
	certPath = filepath.Join(localCertDir, certName)
	keyPath = filepath.Join(localCertDir, keyName)
	return
}

func (g *k8sAccess) addUserAccessToKubeconfig(k2sUserName, certPath, keyPath string, kubeconfigWriter KubeconfigWriter) error {
	if err := kubeconfigWriter.SetCredentials(k2sUserName, certPath, keyPath); err != nil {
		return fmt.Errorf("could not set user credentials for '%s' in kubeconfig: %w", k2sUserName, err)
	}

	if err := g.removeCertDir(certPath); err != nil {
		return fmt.Errorf("could not remove cert dir: %w", err)
	}

	k2sContext := k2sUserName + "@" + k2sClusterName

	if err := kubeconfigWriter.SetContext(k2sContext, k2sUserName, k2sClusterName); err != nil {
		return fmt.Errorf("could not add K8s context for new user in kubeconfig: %w", err)
	}

	kubeconfig, err := g.kubeconfigReader.ReadFile(kubeconfigWriter.FilePath())
	if err != nil {
		return fmt.Errorf("could not read kubeconfig: %w", err)
	}

	targetContext := k2sContext
	resetActiveContext := false

	if kubeconfig.CurrentContext != "" {
		if kubeconfig.CurrentContext == k2sContext {
			slog.Info("New user has already active K2s cluster context, will overwrite it")
		} else {
			slog.Info("New user has already active cluster context, restore needed after verification of K2s access", "context", kubeconfig.CurrentContext)
			targetContext = kubeconfig.CurrentContext
			resetActiveContext = true
		}
	}

	if err := kubeconfigWriter.UseContext(k2sContext); err != nil {
		return fmt.Errorf("could not set K2s context to active for new user in kubeconfig: %w", err)
	}

	if err := g.verifyClusterAccess(kubeconfig, k2sUserName); err != nil {
		return fmt.Errorf("could not verify K8s cluster access: %w", err)
	}

	if resetActiveContext {
		if err := kubeconfigWriter.UseContext(targetContext); err != nil {
			return fmt.Errorf("could not reset context to active for new user in kubeconfig: %w", err)
		}
	}
	return nil
}

func (g *k8sAccess) verifyClusterAccess(kubeconfig *kubeconfig.KubeconfigRoot, k2sUserName string) error {
	userConf, err := kubeconfig.FindUser(k2sUserName)
	if err != nil {
		return err
	}
	clusterConf, err := kubeconfig.FindCluster(k2sClusterName)
	if err != nil {
		return err
	}

	userParam := &cluster.UserParam{
		Name:  k2sUserName,
		Group: g.k2sGroupName,
		Key:   userConf.Details.Key,
		Cert:  userConf.Details.Cert,
	}
	clusterParam := &cluster.ClusterParam{
		Cert:   clusterConf.Details.Cert,
		Server: clusterConf.Details.Server,
	}

	return g.clusterAccess.VerifyAccess(userParam, clusterParam)
}

func (g *k8sAccess) createUserCertOnControlPlane(k2sUserName string) (certName, keyName string, err error) {
	slog.Debug("Generating user cert signed by K8s CA", "username", k2sUserName)

	keyName = k2sUserName + ".key"
	certName = k2sUserName + ".crt"
	requestName := k2sUserName + ".csr"

	removeRemoteDir := "rm -rf " + remoteCertDir
	createRemoteDir := "mkdir " + remoteCertDir
	selectRemoteDir := "cd " + remoteCertDir
	generateKey := fmt.Sprintf("openssl genrsa -out %s %d 2>&1", keyName, privateKeyBits)
	createSignRequest := fmt.Sprintf("openssl req -new -key %s -out %s -subj \"\"/CN=%s/O=%s\"\" 2>&1", keyName, requestName, k2sUserName, g.k2sGroupName)
	signCert := fmt.Sprintf("sudo openssl x509 -req -in %s -CA %s -CAkey %s -CAcreateserial -out %s -days %d 2>&1", requestName, k8sCaCert, k8sCaKey, certName, certValidDays)
	removeSignRequest := "rm -f " + requestName

	createUserCertCmd := removeRemoteDir + " && " +
		createRemoteDir + " && " +
		selectRemoteDir + " && " +
		generateKey + " && " +
		createSignRequest + " && " +
		signCert + " && " +
		removeSignRequest

	if err := g.ssh.Exec(createUserCertCmd); err != nil {
		return "", "", fmt.Errorf("could not generate user cert signed by K8s CA: %w", err)
	}
	return
}

func (g *k8sAccess) initKubeconfigDir(userHomeDir string) (kubeconfigDir string, err error) {
	slog.Debug("Initializing kubeconfig dir", "parent-dir", userHomeDir)

	kubeconfigDirName := filepath.Base(g.kubeconfigDir)
	kubeconfigDir = filepath.Join(userHomeDir, kubeconfigDirName)

	if err := g.fs.CreateDirIfNotExisting(kubeconfigDir); err != nil {
		return "", fmt.Errorf("could not create kubeconfig dir: %w", err)
	}
	return
}

func (g *k8sAccess) fetchUserCertFromControlPlane(targetDir string) error {
	slog.Debug("Copying user cert and key from control-plane")

	if err := g.scp.CopyFromRemote(remoteCertDir, targetDir); err != nil {
		return fmt.Errorf("could not copy user cert and key from control-plane: %w", err)
	}

	slog.Debug("Removing temp cert dir on control-plane")

	removeTempCertDirCmd := "rm -rf " + remoteCertDir

	if err := g.ssh.Exec(removeTempCertDirCmd); err != nil {
		return fmt.Errorf("could not remove temp cert dir on control-plane: %w", err)
	}
	return nil
}

func (g *k8sAccess) readAdminsK2sClusterConfig() (*kubeconfig.ClusterEntry, error) {
	adminKubeconfigPath := filepath.Join(g.kubeconfigDir, kubeconfigName)

	adminConfig, err := g.kubeconfigReader.ReadFile(adminKubeconfigPath)
	if err != nil {
		return nil, fmt.Errorf("could not read admin's kubeconfig '%s': %w", adminKubeconfigPath, err)
	}

	return adminConfig.FindCluster(k2sClusterName)
}

func (g *k8sAccess) removeCertDir(certPath string) error {
	certDir := filepath.Dir(certPath)

	return g.fs.RemoveAll(certDir)
}
