// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package controlplane

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"sync"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
)

type sshProvider interface {
	CreateKeyPair(privateKeyPath, publicKeyComment string) (publicKeyPath string, err error)
}

type aclProvider interface {
	TransferFileOwnership(path string, targetUser *users.OSUser) error
}

type keyAuthorizer interface {
	AuthorizePubKeyOnRemote(publicKeyPath, publicKeyComment string) error
}

type knownHostsCopier interface {
	CopyHostEntries(host string, targetUser *users.OSUser) error
}

type ControlPlaneAdmission struct {
	config           *config.K2sConfig
	sshProvider      sshProvider
	aclProvider      aclProvider
	keyAuthorizer    keyAuthorizer
	knownHostsCopier knownHostsCopier
}

func NewControlPlaneAdmission(config *config.K2sConfig, sshProvider sshProvider, aclProvider aclProvider, keyAuthorizer keyAuthorizer, knownHostsCopier knownHostsCopier) *ControlPlaneAdmission {
	return &ControlPlaneAdmission{
		config:           config,
		sshProvider:      sshProvider,
		aclProvider:      aclProvider,
		keyAuthorizer:    keyAuthorizer,
		knownHostsCopier: knownHostsCopier,
	}
}

func (u *ControlPlaneAdmission) GrantAccess(user *users.OSUser, publicKeyComment string) error {
	slog.Debug("Granting user access to control-plane", "name", user.Name(), "id", user.Id())

	sshDir := host.ResolveTildePrefix(u.config.Host().SshConfig().RelativeDir(), user.HomeDir())
	privateKeyPath := filepath.Join(sshDir, definitions.SSHSubDirName, definitions.SSHPrivateKeyName)

	slog.Debug("SSH private key path determined", "path", privateKeyPath)

	publicKeyPath, err := u.sshProvider.CreateKeyPair(privateKeyPath, publicKeyComment)
	if err != nil {
		return fmt.Errorf("failed to create SSH key pair: %w", err)
	}

	allErrors := []error{nil, nil, nil}
	tasks := sync.WaitGroup{}
	tasks.Add(len(allErrors))

	go func() {
		defer tasks.Done()
		if err := u.aclProvider.TransferFileOwnership(privateKeyPath, user); err != nil {
			allErrors[0] = fmt.Errorf("failed to transfer ownership of SSH key '%s' to user '%s': %w", privateKeyPath, user.Name(), err)
		}
	}()

	go func() {
		defer tasks.Done()
		if err := u.keyAuthorizer.AuthorizePubKeyOnRemote(publicKeyPath, publicKeyComment); err != nil {
			allErrors[1] = fmt.Errorf("failed to authorize public SSH key for '%s' on control-plane: %w", privateKeyPath, err)
		}
	}()

	go func() {
		defer tasks.Done()
		if err := u.knownHostsCopier.CopyHostEntries(u.config.ControlPlane().IpAddress(), user); err != nil {
			allErrors[2] = fmt.Errorf("failed to add control-plane fingerprint to known_hosts: %w", err)
		}
	}()

	tasks.Wait()

	return errors.Join(allErrors...)
}
