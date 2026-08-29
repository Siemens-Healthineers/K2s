// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cluster

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
)

type kubeconfigResolver interface {
	ResolveKubeconfigPath(user *users.OSUser) string
}

type kubeconfigCopier interface {
	CopyClusterConfig(targetPath string) error
}

type certGenerator interface {
	GenerateUserCert(userName string, targetDir string) (certPath, keyPath string, err error)
}

type kubeconfigWriter interface {
	SetUserCredentials(k8sUserName, certPath, keyPath, kubeconfigPath string) error
	SetContext(context, k8sUserName, clusterName, kubeconfigPath string) error
	SetCurrentContext(context, kubeconfigPath string) error
}

type accessVerifier interface {
	VerifyAccess(context, kubeconfigPath string) error
}

type ClusterAdmission struct {
	config             *config.K2sClusterConfig
	kubeconfigResolver kubeconfigResolver
	kubeconfigCopier   kubeconfigCopier
	kubeconfigWriter   kubeconfigWriter
	kubeconfigReader   kubeconfigReader
	certGenerator      certGenerator
	accessVerifier     accessVerifier
}

func NewClusterAdmission(config *config.K2sClusterConfig, kubeconfigResolver kubeconfigResolver, kubeconfigCopier kubeconfigCopier, kubeconfigWriter kubeconfigWriter, kubeconfigReader kubeconfigReader, certGenerator certGenerator, accessVerifier accessVerifier) *ClusterAdmission {
	return &ClusterAdmission{
		config:             config,
		kubeconfigResolver: kubeconfigResolver,
		kubeconfigCopier:   kubeconfigCopier,
		kubeconfigWriter:   kubeconfigWriter,
		kubeconfigReader:   kubeconfigReader,
		certGenerator:      certGenerator,
		accessVerifier:     accessVerifier,
	}
}

func (c *ClusterAdmission) GrantAccess(user *users.OSUser, k8sUserName string) error {
	slog.Debug("Granting user access to Kubernetes cluster", "name", user.Name(), "id", user.Id(), "k8s-user-name", k8sUserName)

	kubeconfigPath := c.kubeconfigResolver.ResolveKubeconfigPath(user)

	allErrors := []error{nil, nil}
	tasks := sync.WaitGroup{}
	tasks.Add(len(allErrors))

	go func() {
		defer tasks.Done()
		if err := c.kubeconfigCopier.CopyClusterConfig(kubeconfigPath); err != nil {
			allErrors[0] = fmt.Errorf("failed to copy cluster config to '%s': %w", kubeconfigPath, err)
		}
	}()

	var tempDir, certPath, keyPath string

	go func() {
		defer tasks.Done()
		var err error
		tempDir, err = os.MkdirTemp("", definitions.SetupNameK2s+"-*")
		if err != nil {
			allErrors[1] = fmt.Errorf("failed to create temporary directory for user certificate generation: %w", err)
			return
		}

		certPath, keyPath, err = c.certGenerator.GenerateUserCert(k8sUserName, tempDir)
		if err != nil {
			allErrors[1] = fmt.Errorf("failed to generate user certificate for user '%s': %w", k8sUserName, err)
		}
	}()
	defer func() {
		err := os.RemoveAll(tempDir)
		if err != nil {
			slog.Error("failed to remove temporary directory for user certificate generation", "path", tempDir, "error", err)
		}
	}()

	tasks.Wait()

	err := errors.Join(allErrors...)
	if err != nil {
		return fmt.Errorf("failed to grant user access to Kubernetes cluster: %w", err)
	}

	k8sContext := k8sUserName + "@" + c.config.Name()

	if err := c.kubeconfigWriter.SetUserCredentials(k8sUserName, certPath, keyPath, kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set user credentials in '%s': %w", kubeconfigPath, err)
	}

	if err := c.kubeconfigWriter.SetContext(k8sContext, k8sUserName, c.config.Name(), kubeconfigPath); err != nil {
		return fmt.Errorf("failed to set user credentials in '%s': %w", kubeconfigPath, err)
	}

	if err := c.accessVerifier.VerifyAccess(k8sContext, kubeconfigPath); err != nil {
		return fmt.Errorf("failed to verify cluster access for user '%s': %w", k8sUserName, err)
	}

	currentContext, err := c.kubeconfigReader.ReadCurrentContext(kubeconfigPath)
	if err != nil {
		return fmt.Errorf("failed to read current context from kubeconfig '%s': %w", kubeconfigPath, err)
	}

	if currentContext == "" {
		if err := c.kubeconfigWriter.SetCurrentContext(k8sContext, kubeconfigPath); err != nil {
			return fmt.Errorf("failed to set current context '%s': %w", kubeconfigPath, err)
		}
	}
	return nil
}
