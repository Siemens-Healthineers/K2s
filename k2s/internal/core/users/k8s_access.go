// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/windows/users"

	"github.com/siemens-healthineers/k2s/internal/http"
	"github.com/siemens-healthineers/k2s/internal/k8s"
	"github.com/siemens-healthineers/k2s/internal/yaml"
)

type k8sAccessGranter struct {
	*commonAccessGranter
	kubeconfigDir string
}

const (
	kubeconfigName  = "config"
	k2sClusterName  = "kubernetes"
	k2sGroupName    = k2sPrefix + "users"
	tempCertDirName = "k2s-user-certs"
	remoteCertDir   = "/tmp/" + tempCertDirName
	privateKeyBits  = 2048
	certValidDays   = 365
	k8sCaCert       = "/etc/kubernetes/pki/ca.crt"
	k8sCaKey        = "/etc/kubernetes/pki/ca.key"
)

func (g *k8sAccessGranter) GrantAccess(winUser *users.WinUser, k2sUserName string) error {
	kubeconfigFile, err := g.deriveKubeconfigFromAdmin(winUser)
	if err != nil {
		return fmt.Errorf("could not derive new kubeconfig from admin's config: %w", err)
	}

	certPath, keyPath, err := g.createK8sUserCert(k2sUserName, kubeconfigFile.Path())
	if err != nil {
		return fmt.Errorf("could not create a new user cert signed by K8s: %w", err)
	}

	if err := g.addUserAccessToKubeconfig(k2sUserName, certPath, keyPath, kubeconfigFile); err != nil {
		return fmt.Errorf("could not add new K8s access to new user's kubeconfig: %w", err)
	}
	return nil
}

func findK2sClusterConf(clusters k8s.Clusters) (*k8s.ClusterConf, error) {
	cluster, err := clusters.Find(k2sClusterName)
	if err != nil {
		return nil, fmt.Errorf("K2s cluster config '%s' not found", k2sClusterName)
	}
	return cluster, nil
}

func (g *k8sAccessGranter) deriveKubeconfigFromAdmin(winUser *users.WinUser) (*k8s.KubeconfigFile, error) {
	kubeconfigDir, err := g.initKubeconfigDir(winUser.HomeDir)
	if err != nil {
		return nil, fmt.Errorf("could not initialize kubeconfig dir for '%s': %w", winUser.Username, err)
	}

	k2sClusterConfig, err := g.readAdminsK2sClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("could not read K2s cluster config from admin's kubeconfig")
	}

	kubeconfigPath := filepath.Join(kubeconfigDir, kubeconfigName)

	kubeconfigFile := k8s.NewKubeconfigFile(kubeconfigPath, g.exec, http.NewRestClient()) // todo: fetch from where?

	if err := kubeconfigFile.SetCluster(k2sClusterConfig); err != nil {
		return nil, fmt.Errorf("could not set K2s cluster config for new user in kubeconfig: %w", err)
	}
	return kubeconfigFile, nil
}

func (g *k8sAccessGranter) createK8sUserCert(k2sUserName string, kubeconfigPath string) (certPath string, keyPath string, err error) {
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

func (g *k8sAccessGranter) addUserAccessToKubeconfig(k2sUserName string, certPath string, keyPath string, kubeconfigFile *k8s.KubeconfigFile) error {
	if err := kubeconfigFile.SetCredentials(k2sUserName, certPath, keyPath); err != nil {
		return fmt.Errorf("could not set user credentials for '%s' in kubeconfig: %w", k2sUserName, err)
	}

	certDir := filepath.Dir(certPath)
	if err := os.RemoveAll(certDir); err != nil {
		return fmt.Errorf("could not remove cert dir: %w", err)
	}

	k2sContext := k2sUserName + "@" + k2sClusterName

	if err := kubeconfigFile.SetContext(k2sContext, k2sUserName, k2sClusterName); err != nil {
		return fmt.Errorf("could not add K8s context for new user in kubeconfig: %w", err)
	}

	kubeconfig, err := kubeconfigFile.ReadFile()
	if err != nil {
		return fmt.Errorf("could not read kubeconfig: %w", err)
	}

	targetContext := k2sContext
	resetActiveContext := false

	if kubeconfig.CurrentContext != "" {
		if kubeconfig.CurrentContext == k2sContext {
			slog.Info("New user has already active K2s cluster context, will overwrite it")
		} else {
			slog.Info("New user has already active cluster context, restore needed after validation of K2s access", "context", kubeconfig.CurrentContext)
			targetContext = kubeconfig.CurrentContext
			resetActiveContext = true
		}
	}

	if err := kubeconfigFile.UseContext(k2sContext); err != nil {
		return fmt.Errorf("could not set K2s context to active for new user in kubeconfig: %w", err)
	}

	if err := kubeconfigFile.TestClusterAccess(k2sUserName, k2sClusterName, k2sGroupName, kubeconfig); err != nil {
		return fmt.Errorf("K8s cluster access test failed: %w", err)
	}

	if resetActiveContext {
		if err := kubeconfigFile.UseContext(targetContext); err != nil {
			return fmt.Errorf("could not reset context to active for new user in kubeconfig: %w", err)
		}
	}
	return nil
}

func (g *k8sAccessGranter) createUserCertOnControlPlane(k2sUserName string) (certName string, keyName string, err error) {
	slog.Debug("Generating user cert signed by K8s CA", "username", k2sUserName)

	keyName = k2sUserName + ".key"
	certName = k2sUserName + ".crt"
	requestName := k2sUserName + ".csr"

	removeRemoteDir := "rm -rf " + remoteCertDir
	createRemoteDir := "mkdir " + remoteCertDir
	selectRemoteDir := "cd " + remoteCertDir
	generateKey := fmt.Sprintf("openssl genrsa -out %s %d 2>&1", keyName, privateKeyBits)
	createSignRequest := fmt.Sprintf("openssl req -new -key %s -out %s -subj \"\"/CN=%s/O=%s\"\" 2>&1", keyName, requestName, k2sUserName, k2sGroupName)
	signCert := fmt.Sprintf("sudo openssl x509 -req -in %s -CA %s -CAkey %s -CAcreateserial -out %s -days %d 2>&1", requestName, k8sCaCert, k8sCaKey, certName, certValidDays)
	removeSignRequest := "rm -f " + requestName

	createUserCertCmd := removeRemoteDir + " && " +
		createRemoteDir + " && " +
		selectRemoteDir + " && " +
		generateKey + " && " +
		createSignRequest + " && " +
		signCert + " && " +
		removeSignRequest

	if err := g.controlPlane.Exec(createUserCertCmd); err != nil {
		return "", "", fmt.Errorf("could not generate user cert signed by K8s CA: %w", err)
	}
	return
}

func (g *k8sAccessGranter) initKubeconfigDir(userHomeDir string) (kubeconfigDir string, err error) {
	slog.Debug("Initializing kubeconfig dir", "parent-dir", userHomeDir)

	kubeconfigDirName := filepath.Base(g.kubeconfigDir)
	kubeconfigDir = filepath.Join(userHomeDir, kubeconfigDirName)

	if err := g.fs.CreateDirIfNotExisting(kubeconfigDir); err != nil {
		return "", fmt.Errorf("could not create kubeconfig dir: %w", err)
	}
	return
}

func (g *k8sAccessGranter) fetchUserCertFromControlPlane(targetDir string) error {
	slog.Debug("Copying user cert and key from control-plane")

	if err := g.controlPlane.CopyFrom(remoteCertDir, targetDir); err != nil {
		return fmt.Errorf("could not copy user cert and key from control-plane: %w", err)
	}

	slog.Debug("Removing temp cert dir on control-plane")

	removeTempCertDirCmd := "rm -rf " + remoteCertDir

	if err := g.controlPlane.Exec(removeTempCertDirCmd); err != nil {
		return fmt.Errorf("could not remove temp cert dir on control-plane: %w", err)
	}
	return nil
}

func (g *k8sAccessGranter) readAdminsK2sClusterConfig() (*k8s.ClusterConf, error) {
	adminKubeconfigPath := filepath.Join(g.kubeconfigDir, kubeconfigName)

	adminConfig, err := yaml.FromFile[k8s.KubeconfigRoot](adminKubeconfigPath)
	if err != nil {
		return nil, fmt.Errorf("could not read admin's kubeconfig '%s': %w", adminKubeconfigPath, err)
	}

	return findK2sClusterConf(adminConfig.Clusters)
}
