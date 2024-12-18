// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package controlplane

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"

	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/core/node"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type fileSystem interface {
	PathExists(path string) bool
	CreateDirIfNotExisting(path string) error
	RemovePaths(files ...string) error
	MatchingFiles(pattern string) (matches []string, err error)
}

type sshKeyGen interface {
	CreateKey(keyPath string, comment string) error
	FindHostInKnownHosts(host string, sshDir string) (hostEntry string, found bool)
	SetHostInKnownHosts(hostEntry string, sshDir string) error
}

type fileAccessControl interface {
	SetOwner(path string, owner string) error
	RemoveInheritance(path string) error
	GrantFullAccess(path string, username string) error
	RevokeAccess(path string, username string) error
}

type copyFunc func(copyOptions node.CopyOptions, connectionOptions ssh.ConnectionOptions) error
type execFunc func(command string, connectionOptions ssh.ConnectionOptions) error

type controlPlaneAccess struct {
	fs          fileSystem
	keygen      sshKeyGen
	exec        execFunc
	copy        copyFunc
	sshOptions  ssh.ConnectionOptions
	acl         fileAccessControl
	adminSshDir string
	ipAddress   string
}

const (
	authorizedKeysPath = "~/.ssh/authorized_keys"
)

func NewControlPlaneAccess(fs fileSystem, keygen sshKeyGen, exec execFunc, copy copyFunc, sshOptions ssh.ConnectionOptions, acl fileAccessControl, adminSshDir string, ipAddress string) *controlPlaneAccess {
	return &controlPlaneAccess{
		fs:          fs,
		keygen:      keygen,
		exec:        exec,
		copy:        copy,
		sshOptions:  sshOptions,
		acl:         acl,
		adminSshDir: adminSshDir,
		ipAddress:   ipAddress,
	}
}

func (g *controlPlaneAccess) GrantAccessTo(user common.User, currentUserName, k2sUserName string) error {
	sshDirName := filepath.Base(g.adminSshDir)
	newUserSshDir := filepath.Join(user.HomeDir(), sshDirName)
	newUserSshKeyPath := ssh.SshKeyPath(newUserSshDir)
	newUserSshControlPlaneDir := filepath.Dir(newUserSshKeyPath)

	if err := g.createSshKey(newUserSshKeyPath, k2sUserName); err != nil {
		return fmt.Errorf("could not create SSH key '%s' for user '%s': %w", newUserSshKeyPath, k2sUserName, err)
	}

	if err := g.transferKeyOwnership(newUserSshKeyPath, currentUserName, user.Name()); err != nil {
		return fmt.Errorf("could not transfer ownership of key file '%s' to '%s': %w", newUserSshKeyPath, user.Name(), err)
	}

	var authErr, addKnownHostsErr error
	tasks := sync.WaitGroup{}
	tasks.Add(2)

	go func() {
		defer tasks.Done()
		if err := g.authorizePubKeyOnControlPlane(newUserSshControlPlaneDir, k2sUserName); err != nil {
			authErr = fmt.Errorf("could not authorize public key on control-plane: %w", err)
		}
	}()

	go func() {
		defer tasks.Done()
		if err := g.addControlPlaneToKnownHosts(newUserSshDir); err != nil {
			addKnownHostsErr = fmt.Errorf("could not add control-plane fingerprint to known_hosts: %w", err)
		}
	}()

	tasks.Wait()

	return errors.Join(authErr, addKnownHostsErr)
}

func (g *controlPlaneAccess) createSshKey(keyPath string, keyComment string) error {
	slog.Debug("Checking if SSH key is already existing", "path", keyPath)

	if g.fs.PathExists(keyPath) {
		slog.Debug("SSH key already existing, overwriting it", "path", keyPath)

		if err := g.removeSShKey(keyPath); err != nil {
			return err
		}
	} else {
		slog.Debug("SSH key not existing", "path", keyPath)
	}

	keyDir := filepath.Dir(keyPath)
	if err := g.fs.CreateDirIfNotExisting(keyDir); err != nil {
		return fmt.Errorf("could not create key dir '%s': %w", keyDir, err)
	}

	slog.Debug("Generating SSH key for new user", "key-path", keyPath)

	if err := g.keygen.CreateKey(keyPath, keyComment); err != nil {
		return fmt.Errorf("could not generate SSH key '%s' for new user: %w", keyPath, err)
	}
	return nil
}

func (g *controlPlaneAccess) removeSShKey(keyPath string) error {
	keyFiles, err := g.fs.MatchingFiles(keyPath + "*")
	if err != nil {
		return fmt.Errorf("could not determine SSH key files: %w", err)
	}

	if err := g.fs.RemovePaths(keyFiles...); err != nil {
		return fmt.Errorf("could not delete existing SSH key files: %w", err)
	}
	return nil
}

func (g *controlPlaneAccess) transferKeyOwnership(keyPath, currentUserName, newOwner string) error {
	if err := g.acl.SetOwner(keyPath, "Administrators"); err != nil {
		return fmt.Errorf("could not set owner of SSH key to Administrators group: %w", err)
	}

	if err := g.acl.RemoveInheritance(keyPath); err != nil {
		return fmt.Errorf("could not remove security inheritance from SSH key: %w", err)
	}

	if err := g.acl.GrantFullAccess(keyPath, newOwner); err != nil {
		return fmt.Errorf("could not grant new user full access to SSH key: %w", err)
	}

	if err := g.acl.RevokeAccess(keyPath, currentUserName); err != nil {
		return fmt.Errorf("could not revoke access to SSH key for current user: %w", err)
	}
	return nil
}

func (g *controlPlaneAccess) authorizePubKeyOnControlPlane(keyDir string, k2sUserName string) error {
	localPubKeyPath := filepath.Join(keyDir, ssh.SshPubKeyName)
	remotePubKeyPath := fmt.Sprintf("/tmp/%s", ssh.SshPubKeyName)
	removeRemotePubKeyCmd := fmt.Sprintf("rm -f %s", remotePubKeyPath)

	slog.Debug("Removing existing pub SSH key from control-plane temp dir")
	if err := g.exec(removeRemotePubKeyCmd, g.sshOptions); err != nil {
		return fmt.Errorf("could not remove existing SSH public key from control-plane temp dir: %w", err)
	}

	slog.Debug("Copying pub SSH key to control-plane temp dir")
	copyOptions := node.CopyOptions{
		Source:    localPubKeyPath,
		Target:    remotePubKeyPath,
		Direction: node.CopyToNode,
	}

	if err := g.copy(copyOptions, g.sshOptions); err != nil {
		return fmt.Errorf("could not copy SSH public key to control-plane temp dir: %w", err)
	}

	deleteObsoletePubKeyFromAuthKeys := fmt.Sprintf("sudo sed -i '/.*%s.*/d' %s", k2sUserName, authorizedKeysPath)
	addNewPubKeyToAuthKeys := fmt.Sprintf("sudo cat %s >> %s", remotePubKeyPath, authorizedKeysPath)
	removePubKeyFile := "rm -f " + remotePubKeyPath

	authorizeRemotePubKeyCmd := deleteObsoletePubKeyFromAuthKeys + " && " +
		addNewPubKeyToAuthKeys + " && " +
		removePubKeyFile

	slog.Debug("Adding SSH public key to authorized keys file")
	if err := g.exec(authorizeRemotePubKeyCmd, g.sshOptions); err != nil {
		return fmt.Errorf("could not add SSH public key to authorized keys file: %w", err)
	}
	return nil
}

func (g *controlPlaneAccess) addControlPlaneToKnownHosts(newUserSshDir string) error {
	controlPlaneEntry, found := g.keygen.FindHostInKnownHosts(g.ipAddress, g.adminSshDir)
	if !found {
		return fmt.Errorf("could not find any control-plane entry for host '%s' in '%s'", g.ipAddress, g.adminSshDir)
	}

	if err := g.keygen.SetHostInKnownHosts(controlPlaneEntry, newUserSshDir); err != nil {
		return fmt.Errorf("could not add control-plane entry to new user's known_hosts: %w", err)
	}
	return nil
}
